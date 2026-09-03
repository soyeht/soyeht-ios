import SoyehtCore
import SwiftUI

/// The home the phone lands on after pairing: the house, its Mac, and the
/// sessions running on it.
///
/// The old home was a list of everything the phone could reach — servers,
/// macs, base machines, apps — each with its own header. This one answers the
/// only question a phone that just paired has: *what is running on my Mac,
/// and how do I start something new?* Everything else moved behind "Other
/// machines", which pushes the instance list unchanged.
struct HomeView: View {
    @ObservedObject var model: HomeViewModel

    /// Opens a pane that already exists on the Mac. Returns `false` when the
    /// attach failed so the caller's own error surface stays the one that
    /// speaks.
    let onOpenSession: (_ macID: UUID, _ pane: PaneEntry) async -> Bool
    let onOtherMachines: () -> Void
    let onSettings: () -> Void

    private let palette = NeoPalette.cloud

    /// The waiting card tells the truth for about twenty seconds — the window
    /// in which a just-paired Mac reliably lands in the registry. Past that
    /// the wait is not a wait any more, it is a Mac that is asleep or closed,
    /// and the card says so instead of spinning forever.
    @State private var macIsOverdue = false

    var body: some View {
        ZStack {
            palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    macCard
                    sessionsSection
                    otherMachinesRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .environment(\.neoPalette, palette)
        .accessibilityIdentifier(AccessibilityID.Home.screen)
        .alert(
            Text(model.errorMessage ?? ""),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(String(
                localized: "home.error.dismiss",
                defaultValue: "OK",
                comment: "Only button of the alert that reports why a session could not be opened."
            )) { model.errorMessage = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.houseName)
                .font(NeoFont.title)
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .accessibilityIdentifier(AccessibilityID.Home.houseName)

            Spacer(minLength: 12)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Home.settingsButton)
            .accessibilityLabel(Text(LocalizedStringResource(
                "home.settings.a11y",
                defaultValue: "Settings",
                comment: "Accessibility label for the gear in the top-right of the home screen."
            )))
        }
    }

    // MARK: - The Mac

    @ViewBuilder
    private var macCard: some View {
        if model.mac == nil {
            // The seconds between "Open a terminal" and the Mac landing in the
            // registry. They used to be spent on a different screen entirely —
            // raw household and person identifiers, a row reading
            // "[owned mac] —", and then a silent swap to this one. Same wait,
            // said in the same voice as everything around it.
            NeoCard(palette: palette) {
                HStack(spacing: 14) {
                    if macIsOverdue {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(palette.muted)
                            .frame(width: 22)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 22)
                    }

                    Text(macIsOverdue ? overdueMessage : arrivingMessage)
                        .font(NeoFont.body)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .accessibilityIdentifier(AccessibilityID.Home.macArriving)
            .task(id: model.mac == nil) {
                macIsOverdue = false
                guard model.mac == nil else { return }
                try? await Task.sleep(nanoseconds: 20 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                macIsOverdue = true
            }
        } else if let mac = model.mac {
            NeoCard(palette: palette) {
                HStack(spacing: 14) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(palette.accent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(mac.name)
                            .font(NeoFont.heading)
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Text(statusLabel(for: mac.status))
                            .font(NeoFont.caption)
                            .foregroundStyle(palette.muted)
                    }

                    Spacer(minLength: 8)

                    NeoStatusDot(isLive: mac.isOnline, palette: palette)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Home.macCard)
            .accessibilityLabel(Text(verbatim: "\(mac.name), \(statusLabel(for: mac.status))"))
        }
    }

    private var arrivingMessage: LocalizedStringResource {
        LocalizedStringResource(
            "home.mac.arriving",
            defaultValue: "Getting your Mac ready…",
            comment: "Shown on the home in the seconds after pairing, before the Mac appears."
        )
    }

    private var overdueMessage: LocalizedStringResource {
        LocalizedStringResource(
            "home.mac.arriving.slow",
            defaultValue: "Your Mac hasn't checked in. Open Soyeht on it and this fills in by itself.",
            comment: "Replaces the waiting message on the home when the Mac has not appeared after twenty seconds — asleep, closed, or off the network."
        )
    }

    private func statusLabel(for status: HomeViewModel.MacStatus) -> String {
        switch status {
        case .online:
            return String(
                localized: "home.macStatus.online",
                defaultValue: "online",
                comment: "Subtitle under the Mac on the home screen when it is connected."
            )
        case .connecting:
            return String(
                localized: "home.macStatus.connecting",
                defaultValue: "connecting…",
                comment: "Subtitle under the Mac on the home screen while the connection is being made."
            )
        case .offline:
            return String(
                localized: "home.macStatus.offline",
                defaultValue: "offline — open Soyeht on your Mac",
                comment: "Subtitle under the Mac on the home screen when it cannot be reached."
            )
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "home.sessions.title",
                defaultValue: "Sessions",
                comment: "Header over the list of terminal sessions running on the Mac."
            ))
            .font(NeoFont.caption)
            .foregroundStyle(palette.muted)
            .textCase(.uppercase)

            if let mac = model.mac, !mac.panes.isEmpty {
                ForEach(mac.panes) { pane in
                    HomeSessionRow(pane: pane, palette: palette) {
                        Task { _ = await onOpenSession(mac.id, pane) }
                    }
                }
            } else {
                Text(LocalizedStringResource(
                    "home.sessions.empty",
                    defaultValue: "Nothing is running yet.",
                    comment: "Shown in place of the session list when the Mac has no open panes."
                ))
                .font(NeoFont.body)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                .neoWell(palette, radius: NeoRadius.card)
                .accessibilityIdentifier(AccessibilityID.Home.sessionsEmpty)
            }

            newSessionButton
                .padding(.top, 4)
        }
    }

    private var newSessionButton: some View {
        Button {
            Task {
                guard let pane = await model.openNewSession(), let mac = model.mac else { return }
                _ = await onOpenSession(mac.id, pane)
            }
        } label: {
            HStack(spacing: 8) {
                if model.isOpeningSession {
                    ProgressView().tint(palette.onAccent)
                } else {
                    Image(systemName: "plus")
                }
                Text(LocalizedStringResource(
                    "home.newSession",
                    defaultValue: "New session",
                    comment: "Primary button on the home screen — opens a shell on the paired Mac."
                ))
            }
        }
        // A dimmed accent pill still reads as an accent pill: measured on the
        // device, a tap in the seconds before the presence socket
        // authenticates does nothing at all and looks like the app ignored it.
        // The secondary shape says "not yet" at a glance, and the Mac card
        // directly above says why.
        .buttonStyle(NeoPillButtonStyle(canOpenSession ? .primary : .secondary, palette: palette))
        .disabled(model.isOpeningSession || !canOpenSession)
        .accessibilityIdentifier(AccessibilityID.Home.newSessionButton)
    }

    /// The Mac has to be there to open a pane on it. `.connecting` counts as
    /// not yet: the socket is up but the handshake has not finished, and an
    /// `open_pane` sent then is refused.
    private var canOpenSession: Bool { model.mac?.isOnline == true }

    // MARK: - Everything else

    @ViewBuilder
    private var otherMachinesRow: some View {
        Button(action: onOtherMachines) {
            HStack(spacing: 10) {
                Text(LocalizedStringResource(
                    "home.otherMachines",
                    defaultValue: "Other machines",
                    comment: "Link on the home screen to the full list of servers, machines and apps."
                ))
                if model.otherMachineCount > 0 {
                    Text(verbatim: "\(model.otherMachineCount)")
                        .font(NeoFont.caption)
                        .foregroundStyle(palette.muted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(NeoLinkButtonStyle(palette: palette))
        .accessibilityIdentifier(AccessibilityID.Home.otherMachinesButton)
    }
}
