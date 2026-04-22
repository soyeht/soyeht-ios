import SwiftUI
import SoyehtCore

/// Top-level destination of the welcome flow. Two branches:
///   - install theyOS on this Mac (new users, US-01/US-02)
///   - connect to an existing server via `theyos://` link (US-04)
///
/// Both branches terminate by invoking `onPaired` — the window controller
/// closes the Welcome window and the AppDelegate opens the main workspace.
struct WelcomeRootView: View {
    enum Destination: Hashable {
        case localInstall
        case remoteConnect
    }

    let onPaired: () -> Void

    @State private var path: [Destination] = []

    var body: some View {
        NavigationStack(path: $path) {
            landing
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .localInstall:
                        LocalInstallView(onPaired: onPaired)
                    case .remoteConnect:
                        RemoteConnectView(onPaired: onPaired)
                    }
                }
        }
        .frame(width: 640, height: 540)
        .background(BrandColors.surfaceDeep)
        .preferredColorScheme(.dark)
    }

    private var landing: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("welcome.landing.title")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                Text("welcome.landing.subtitle")
                    .font(.system(size: 13))
                    .foregroundColor(BrandColors.textMuted)
            }

            cards

            Spacer()
        }
        .padding(32)
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 16) {
            WelcomeCard(
                title: "welcome.card.localInstall.title",
                subtitle: "welcome.card.localInstall.subtitle",
                badge: "welcome.card.localInstall.badge",
                action: { path.append(.localInstall) }
            )
            WelcomeCard(
                title: "welcome.card.remoteConnect.title",
                subtitle: "welcome.card.remoteConnect.subtitle",
                badge: nil,
                action: { path.append(.remoteConnect) }
            )
        }
    }
}

struct WelcomeCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let badge: LocalizedStringKey?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                if let badge {
                    Text(badge)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(BrandColors.accentGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(BrandColors.accentGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .padding(20)
            .background(hovering ? Color.white.opacity(0.07) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hovering ? BrandColors.accentGreen.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
