import ElectricityCore
import SwiftUI

/// List of running conversations. Clicking a row brings its terminal or app to the front.
struct ActiveSessionsList: View {
    let sessions: [ActiveSession]
    let settings: AppSettings
    var compact = false
    var onJump: (() -> Void)?

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            ForEach(sessions) { session in
                ActiveSessionRow(session: session, settings: settings, compact: compact) {
                    TerminalJumper.jump(to: session)
                    onJump?()
                }
            }
        }
    }
}

private struct ActiveSessionRow: View {
    let session: ActiveSession
    let settings: AppSettings
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusLight(status: session.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.isClaudeChat ? String(localized: "sessions.chat.title")
                         : session.title ?? Formatting.projectName(session.projectPath))
                        .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        // The panel is narrow: the project name is left out there and shown on hover.
                        if session.title != nil && !compact {
                            Text(Formatting.projectName(session.projectPath))
                        }
                        Text(SourceText.name(session.source, client: session.client))
                        statusText
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if session.isClaudeChat {
                    // The chat keeps no usage records on this Mac.
                    Text(verbatim: "–")
                        .font(compact ? .callout : .body)
                        .foregroundStyle(.secondary)
                        .help(Text("sessions.chat.noEnergy"))
                } else {
                    RollingText(settings.formatEnergy(session.energyWh).text)
                        .font(compact ? .callout : .body)
                        .foregroundStyle(.secondary)
                }
                SymbolIcon(Icon("arrow.up.forward.app"), size: 13)
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 8)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.isClaudeChat ? String(localized: "sessions.chat.help") : session.projectPath ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("sessions.jump"))
    }

    @ViewBuilder
    private var statusText: some View {
        let key: String = switch session.status {
        case .running: session.isClaudeChat ? "sessions.chat.replying" : "sessions.status.running"
        case .done: session.isClaudeChat && !session.chatReplied ? "sessions.chat.used" : "sessions.status.done"
        case .waiting: "sessions.status.waiting"
        }
        if let since = session.statusSince {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(String(format: String(localized: String.LocalizationValue(key + ".since")), Formatting.relative(since, now: context.date)))
            }
        } else {
            Text(String(localized: String.LocalizationValue(key)))
        }
    }
}

/// A plain dot when the turn has finished (green) or waits for the user (orange), and a spinning ring, like a page
/// loading indicator, while the agent works. No glow or pulse. With Reduce Motion the ring does not spin.
///
/// The angle comes from the clock, not from a repeating animation: a repeating animation started in `onAppear` stopped
/// when the same row went from finished back to running (its state already said "spinning") or when the row was
/// redrawn inside another animation.
struct StatusLight: View {
    let status: ActiveSession.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch status {
            case .running:
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
                }
            case .done:
                Circle().fill(Palette.clean).frame(width: 8, height: 8)
            case .waiting:
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
