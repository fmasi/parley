import SwiftUI
import AppKit
import TranscriberCore

// Shared design-language components for the v0.8.x UI revamp.
// See docs/design/design-system-0.8.x.md ("Quiet Confidence") for the tokens
// these implement: 4pt grid, reserved-red policy, SF Symbols-only iconography.

// MARK: - MenuRowLabel / MenuActionRow

/// The visual body of a menu-panel row: 20pt icon column, title (+ optional
/// subtitle), subtle primary wash on hover. Split from `MenuActionRow` so
/// non-Button controls (e.g. SettingsAccess's `SettingsLink`) can share the
/// exact same appearance.
struct MenuRowLabel: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var isDestructive: Bool = false
    var isDisabled: Bool = false

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering && !isDisabled ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// A hover-highlighted action row for the window-style menu bar panel.
/// Mimics first-party panel rows (Wi-Fi, Control Center).
struct MenuActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(
                icon: icon,
                title: title,
                subtitle: subtitle,
                isDestructive: isDestructive,
                isDisabled: isDisabled
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - IconTile

/// System Settings-style 26×26 icon tile: white SF Symbol on a muted color.
struct IconTile: View {
    let systemImage: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - StatusDot

/// An 8pt state dot. Pulses softly while `pulsing` is true (recording).
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false

    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            // Opacity tracks `dimmed` alone. Folding `pulsing` into the
            // expression made a stopping dot snap back to full brightness:
            // `pulsing` went false before SwiftUI could animate the change.
            .opacity(dimmed ? 0.35 : 1.0)
            .animation(
                pulsing
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.2),
                value: dimmed
            )
            .onAppear { dimmed = pulsing }
            .onChange(of: pulsing) { _, now in dimmed = now }
    }
}

// MARK: - AlertBanner

/// A quiet inline banner replacing the old disabled-Button status menu rows.
/// Severity drives the symbol color only — the card itself stays calm.
struct AlertBanner: View {
    enum Severity {
        case warning   // recoverable: interruptions, transient errors
        case critical  // unrecoverable failure

        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "exclamationmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .warning: return .orange
            case .critical: return .red
            }
        }
    }

    let severity: Severity
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity.symbol)
                .foregroundStyle(severity.color)
                .font(.footnote)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quinary)
        )
    }
}

// MARK: - Folder picking

/// The one folder-picker used everywhere the user chooses a recordings
/// location (Setup, Settings). Returns the chosen path, or nil if cancelled.
@MainActor
func chooseFolderPath(message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Select"
    panel.message = message
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path(percentEncoded: false)
}

/// Standardizes a path and abbreviates the home directory to `~` for display.
func abbreviatedDisplayPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let standardized = (expanded as NSString).standardizingPath
    return standardized.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

// Timer formatting (`recordingTimerString`) lives in TranscriberCore so the
// test suite can reach it.
