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
                    Text(session.title ?? Formatting.projectName(session.projectPath))
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
                RollingText(settings.formatEnergy(session.energyWh).text)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.secondary)
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
        .help(session.projectPath ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("sessions.jump"))
    }

    @ViewBuilder
    private var statusText: some View {
        let key: String = switch session.status {
        case .running: "sessions.status.running"
        case .done: "sessions.status.done"
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

/// Blue and pulsing while running, green when finished, orange when waiting for the user.
struct StatusLight: View {
    let status: ActiveSession.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .running: .blue
        case .done: Palette.clean
        case .waiting: .orange
        }
    }

    var body: some View {
        ZStack {
            if status == .running && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1 : 0.5)
                    .opacity(pulse ? 0 : 1)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
                    }
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 3)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
