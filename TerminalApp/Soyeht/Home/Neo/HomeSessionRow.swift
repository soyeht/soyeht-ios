import SoyehtCore
import SwiftUI

/// One session running on the Mac, as a raised face on the canvas.
///
/// The row says three things: what is running (icon + title), whether it is
/// still alive (the status dot), and that it can be opened (the chevron).
/// Everything else the pane knows — workspace, window, working directory —
/// belongs to the terminal, not to a list the user scans.
struct HomeSessionRow: View {
    let pane: PaneEntry
    let palette: NeoPalette
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                Image(systemName: pane.iconName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(NeoFont.body)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(NeoFont.caption)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                NeoStatusDot(isLive: pane.isLive, palette: palette)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .neoRaised(palette, radius: NeoRadius.card, elevation: .chip)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Home.sessionRow(pane.id))
        .accessibilityLabel(Text(verbatim: "\(pane.title), \(subtitle)"))
    }

    private var subtitle: String {
        switch pane.agent {
        case PaneWireAgent.shell:
            return String(
                localized: "home.session.shell",
                defaultValue: "Shell",
                comment: "Title of a plain shell session opened from the phone."
            )
        default:
            return pane.agent
        }
    }
}
