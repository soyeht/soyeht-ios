import SoyehtCore
import SwiftUI

/// Where the macOS build lives. Named here because the screen that offers it
/// is the only one that sends it.
enum MacDownloadLink {
    static let latestDMG = URL(string: "https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg")!
}

/// I2 — the one question the phone asks before it starts looking.
///
/// The old flow asked three: which platform, is the Mac nearby, and do you
/// want the download link. Two of them the phone can answer on its own — it
/// is going to look for the Mac either way, and "nearby" stopped meaning
/// anything the moment pairing went over Tailscale. What is left is the only
/// answer that changes what happens next: is Soyeht on the Mac yet?
struct MacPresenceQuestionView: View {
    let onAlreadyInstalled: () -> Void
    let onNeedsInstall: () -> Void
    let onLinux: () -> Void

    @State private var showShareSheet = false
    private let palette = NeoPalette.cloud

    var body: some View {
        OnboardingScaffold(palette: palette) {
            VStack(spacing: 16) {
                Text(LocalizedStringResource(
                    "onboarding.macPresence.title",
                    defaultValue: "Is Soyeht already on your Mac?",
                    comment: "I2 title — the only question asked before the phone starts looking."
                ))
                .font(NeoFont.title)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)

                Text(LocalizedStringResource(
                    "onboarding.macPresence.body",
                    defaultValue: "Your Mac runs the sessions. This iPhone opens them.",
                    comment: "I2 body — one line saying why the Mac has to come first."
                ))
                .font(NeoFont.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            VStack(spacing: 12) {
                Button(action: onAlreadyInstalled) {
                    Text(LocalizedStringResource(
                        "onboarding.macPresence.yes",
                        defaultValue: "Yes, it's installed",
                        comment: "I2 primary button — go straight to looking for the Mac."
                    ))
                }
                .buttonStyle(NeoPillButtonStyle(.primary, palette: palette))
                .accessibilityIdentifier(AccessibilityID.Onboarding.macPresenceYes)

                Button {
                    showShareSheet = true
                } label: {
                    Text(LocalizedStringResource(
                        "onboarding.macPresence.notYet",
                        defaultValue: "Not yet — send me the link",
                        comment: "I2 secondary button — share the macOS download link, then keep looking."
                    ))
                }
                .buttonStyle(NeoPillButtonStyle(.secondary, palette: palette))
                .accessibilityIdentifier(AccessibilityID.Onboarding.macPresenceNotYet)

                Button(action: onLinux) {
                    Text(LocalizedStringResource(
                        "onboarding.macPresence.linux",
                        defaultValue: "I use Linux, not a Mac",
                        comment: "I2 tertiary link — route to the Linux pairing guide."
                    ))
                }
                .buttonStyle(NeoLinkButtonStyle(palette: palette))
                .accessibilityIdentifier(AccessibilityID.Onboarding.macPresenceLinux)
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: onNeedsInstall) {
            // The phone starts looking as soon as the sheet closes, whether or
            // not the link was actually sent: the Mac may already be being set
            // up by someone else in the house, and a phone that sat still
            // after "Not yet" was the dead end this screen replaces.
            ShareSheet(items: [MacDownloadLink.latestDMG])
        }
    }
}
