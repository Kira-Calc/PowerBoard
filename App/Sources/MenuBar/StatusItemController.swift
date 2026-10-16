import AppKit
import ElectricityCore
import SwiftUI

/// Menu bar status items (SPEC 8.1): one combined item, or one item per metric.
/// Labels are drawn with SwiftUI so numbers roll when they change. Clicking any item opens the popover.
@MainActor
final class StatusItemController: NSObject {
    private static let maxItemWidth: CGFloat = 180

    /// A status item position: the combined item, or one metric in separate mode.
    private enum Slot: Hashable {
        case combined
        case metric(MenuBarMetric)
    }

    private let model: AppModel
    private let settings: AppSettings
    private var items: [Slot: (item: NSStatusItem, host: LabelHostingView)] = [:]
    private let popover = NSPopover()
    private var lastAlertShown: Date?
    /// Closes a panel that opened by itself for a finished turn.
    private var autoClose: Task<Void, Never>?
    /// How long a panel opened for a finished turn stays before it closes by itself.
    private static let autoCloseDelay: Duration = .seconds(3)

    init(model: AppModel, settings: AppSettings, openDashboard: @escaping (DashboardSection?) -> Void) {
        self.model = model
        self.settings = settings
        super.init()

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            model: model,
            settings: settings,
            openDashboard: { [weak self] section in
                self?.popover.performClose(nil)
                openDashboard(section)
            },
            quit: { NSApp.terminate(nil) },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        ))

        render()
    }

    /// Re-renders whenever an observed property of the model or settings changes.
    private func render() {
        withObservationTracking {
            let slots: [(Slot, [MenuBarMetric])] = settings.menuBarSplit == .combined
                ? [(.combined, settings.combinedDisplay.metrics)]
                : MenuBarMetric.allCases.map { (.metric($0), [$0]) }
            syncItems(slots.map(\.0))
            for (index, (slot, metrics)) in slots.enumerated() {
                update(slot, metrics: metrics, alert: index == 0 && model.completionAlert != nil)
            }
            openForCompletionIfNeeded(slots.first.map(\.0))
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    private func syncItems(_ wanted: [Slot]) {
        for (slot, entry) in items where !wanted.contains(slot) {
            NSStatusBar.system.removeStatusItem(entry.item)
            items[slot] = nil
        }
        // Create from right to left so the items appear in order: energy, tokens, carbon.
        for slot in wanted.reversed() where items[slot] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let host = LabelHostingView(rootView: StatusItemLabel(segments: [], active: false, alert: false))
            if let button = item.button {
                button.target = self
                button.action = #selector(togglePopover(_:))
                button.title = ""
                button.image = nil
                host.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    host.topAnchor.constraint(equalTo: button.topAnchor),
                    host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                ])
            }
            items[slot] = (item, host)
        }
    }

    /// Opens the panel once per completed turn, without taking keyboard focus from the frontmost app.
    private func openForCompletionIfNeeded(_ slot: Slot?) {
        guard let alert = model.completionAlert, alert.at != lastAlertShown else { return }
        lastAlertShown = alert.at
        guard settings.completionOpensPopover, !popover.isShown,
              let slot, let button = items[slot]?.item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        scheduleAutoClose()
    }

    /// Closes the panel after `autoCloseDelay`, but not while the pointer is over it: then it waits until the pointer
    /// leaves and closes one second later. Opening the panel by hand cancels this.
    private func scheduleAutoClose() {
        autoClose?.cancel()
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: Self.autoCloseDelay)
            while !Task.isCancelled {
                guard let self, self.popover.isShown else { return }
                if let frame = self.popover.contentViewController?.view.window?.frame, frame.contains(NSEvent.mouseLocation) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                self.popover.performClose(nil)
                return
            }
        }
    }

    private func update(_ slot: Slot, metrics: [MenuBarMetric], alert: Bool) {
        guard let (item, host) = items[slot], let button = item.button else { return }
        let snapshot = model.snapshot
        let segments = metrics.map { metric in
            StatusItemLabel.Segment(
                metric: metric,
                content: settings.content(for: metric),
                text: valueText(metric: metric, snapshot: snapshot),
                sparkline: snapshot?.lastHourSparklineWh ?? [],
                grid: metric == .energy && model.gridConfigured ? model.mainGridStatus : nil
            )
        }
        host.rootView = StatusItemLabel(segments: segments, active: model.isIncreasing, alert: alert)
        host.layoutSubtreeIfNeeded()
        item.length = min(host.fittingSize.width.rounded(.up), Self.maxItemWidth)

        var description = metrics.map { accessibilityText(metric: $0, snapshot: snapshot) }.joined(separator: "\n")
        if alert, let finished = model.completionAlert {
            description = String(format: String(localized: "sessions.alert"), Formatting.projectName(finished.session.projectPath)) + "\n" + description
        }
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func valueText(metric: MenuBarMetric, snapshot: Snapshot?) -> String {
        guard let today = snapshot?.today else { return "--" }
        switch metric {
        case .energy: return settings.formatEnergy(settings.displayedEnergy(today).total.mid).text
        case .tokens: return ValueFormatting.tokens(today.tokens.total)
        case .carbon: return ValueFormatting.carbon(grams: today.co2G).text
        }
    }

    private func accessibilityText(metric: MenuBarMetric, snapshot: Snapshot?) -> String {
        guard let today = snapshot?.today else { return AppIdentity.displayName }
        switch metric {
        case .energy where model.gridConfigured && model.mainGridStatus != nil:
            let energy = settings.displayedEnergy(today)
            let range = settings.formatEnergy(energy.server)
            return String(format: settings.dayText("statusItem.energy.tooltip"), range.mid.text, range.low.text, range.high.text)
                + "\n" + GridText.summary(model.mainGridStatus!)
        case .energy:
            let energy = settings.displayedEnergy(today)
            let range = settings.formatEnergy(energy.server)
            let server = String(format: settings.dayText("statusItem.energy.tooltip"), range.mid.text, range.low.text, range.high.text)
            guard let local = energy.local else { return server }
            return server + "\n" + String(format: settings.dayText("statusItem.local.tooltip"), settings.formatEnergy(local).text)
        case .tokens:
            return String(format: settings.dayText("statusItem.tokens.tooltip"), ValueFormatting.tokens(today.tokens.total))
        case .carbon:
            return String(format: settings.dayText("statusItem.carbon.tooltip"), ValueFormatting.carbon(grams: today.co2G).text, Units.co2e)
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        autoClose?.cancel()
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Hosting view that lets clicks pass through to the status bar button underneath.
final class LabelHostingView: NSHostingView<StatusItemLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The content of a status item: one or more segments of icon, number or graph.
struct StatusItemLabel: View {
    struct Segment: Hashable {
        var metric: MenuBarMetric
        var content: MenuBarContent
        var text: String
        var sparkline: [Double]
        /// Grid level next to the energy number; nil when no grid data source is set up.
        var grid: GridStatus? = nil
    }

    let segments: [Segment]
    /// Shows a moving bar under the label while usage is increasing.
    let active: Bool
    /// Shows a completion icon in place of the first icon after a conversation finishes a turn.
    let alert: Bool

    var body: some View {
        HStack(spacing: 6) {
            if alert {
                CompletionIcon()
                    .transition(.scale.combined(with: .opacity))
            }
            ForEach(Array(segments.enumerated()), id: \.element.metric) { index, segment in
                SegmentView(segment: segment, hideIcon: alert && index == 0)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: alert)
        .padding(.horizontal, 4)
        .frame(height: 22)
        .overlay(alignment: .bottom) {
            // Only exists while active, so the animation does not run in the background.
            if active {
                ActivityBar()
                    .frame(height: 2)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 1)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: active)
        .fixedSize()
    }

    private struct SegmentView: View {
        let segment: Segment
        let hideIcon: Bool

        var body: some View {
            HStack(spacing: 3) {
                switch segment.content {
                case .iconOnly:
                    if !hideIcon { icon }
                case .iconAndValue:
                    if !hideIcon { icon }
                    value
                case .valueOnly:
                    value
                case .sparkline:
                    Sparkline(values: segment.sparkline)
                        .frame(width: 30, height: 13)
                }
            }
        }

        private var icon: some View {
            SymbolIcon(Self.iconName(segment.metric), size: 14)
        }

        private var value: some View {
            HStack(spacing: 4) {
                RollingText(segment.text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let grid = segment.grid {
                    GridDot(level: grid.level, certainty: grid.certainty, size: 6)
                }
            }
        }

        static func iconName(_ metric: MenuBarMetric) -> Icon {
            switch metric {
            case .energy: Icons.lightning
            case .tokens: Icons.coins
            case .carbon: Icons.cloud
            }
        }
    }
}

/// Bars for the last hour of energy use. Empty buckets show as a 1 pt baseline.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let maxValue = values.max() ?? 0
            let count = max(values.count, 1)
            let gap: CGFloat = 1
            let width = (proxy.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Rectangle()
                        .frame(width: width, height: maxValue > 0 ? max(1, proxy.size.height * value / maxValue) : 1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }
}

/// A thin track with a light band sliding across it, like a page loading bar.
/// With Reduce Motion the band stays still.
struct ActivityBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let width = proxy.size.width
                let bandWidth = max(width * 0.4, 8)
                // One pass every 1.2 seconds, from fully left of the track to fully right.
                let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                let x = -bandWidth + (width + bandWidth) * phase
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.primary.opacity(0), .primary, .primary.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: bandWidth)
                        .offset(x: x)
                }
                .clipShape(Capsule())
            }
        }
    }
}

/// Green check that bounces when it appears and then pulses until the alert ends.
struct CompletionIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white, Palette.clean)
            .symbolEffect(.bounce, options: .repeat(2), value: bounce)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .onAppear { if !reduceMotion { bounce += 1 } }
    }
}
