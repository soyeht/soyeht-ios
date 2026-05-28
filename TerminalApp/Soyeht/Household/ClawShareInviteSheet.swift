import SwiftUI
import SoyehtCore

/// SwiftUI surface for the claw-share invite flow.
///
/// Copy is deliberately plain English — no technical terms like
/// "relay", "Nostr", "bootstrap", or "data plane" — because the friend
/// receiving the share is not a household operator. Every state maps
/// to one screen with one primary action and (at most) one secondary
/// action.
///
/// Apple-grade gating:
/// - `.acceptedAwaitingDataPlane` never advertises "open" or
///   "connect". Copy: "Almost ready — this share isn't openable yet".
/// - Terminal failures land on a single screen with "Done", no
///   automatic retry.
struct ClawShareInviteSheet: View {
    @ObservedObject var center: ClawShareInviteCenter

    var body: some View {
        VStack(spacing: 24) {
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var content: some View {
        switch center.state {
        case .idle:
            EmptyView()

        case .acceptanceReady(let invite):
            acceptanceView(invite: invite)

        case .claimInFlight:
            ProgressView("setting up your access…")
                .progressViewStyle(.circular)
                .accessibilityIdentifier("ClawShareInviteSheet.submitting")

        case .acceptedAwaitingDataPlane:
            awaitingDataPlaneView

        case .failed(let error):
            failureView(error: error)
        }
    }

    private func acceptanceView(invite: ClawShareInvite) -> some View {
        VStack(spacing: 16) {
            Text("you've been invited to a shared workspace")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(invite.clawId)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("ClawShareInviteSheet.clawId")
            Spacer().frame(height: 8)
            Button {
                Task { await center.accept() }
            } label: {
                Text("accept")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ClawShareInviteSheet.accept")
            Button {
                Task { await center.decline() }
            } label: {
                Text("decline")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ClawShareInviteSheet.decline")
        }
    }

    private var awaitingDataPlaneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("almost ready")
                .font(.title3.weight(.semibold))
            Text("this share isn't openable yet — your access is saved and will become live when the workspace is reachable.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ClawShareInviteSheet.awaiting.copy")
            Button {
                Task { await center.acknowledgeFailure() }
            } label: {
                Text("done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ClawShareInviteSheet.awaiting.done")
        }
    }

    private func failureView(error: ClawShareError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(failureTitle(error))
                .font(.title3.weight(.semibold))
            Text(failureCopy(error))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ClawShareInviteSheet.failure.copy")
            Button {
                Task { await center.acknowledgeFailure() }
            } label: {
                Text("done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ClawShareInviteSheet.failure.done")
        }
    }

    private func failureTitle(_ error: ClawShareError) -> String {
        switch error {
        case .inviteExpired:
            return "this invitation has expired"
        case .inviteMalformed:
            return "this invitation isn't valid"
        case .iosClaimRelayNotYetWired:
            return "iphone isn't supported yet"
        default:
            return "couldn't complete this share"
        }
    }

    private func failureCopy(_ error: ClawShareError) -> String {
        switch error {
        case .inviteExpired:
            return "ask the inviter to send a fresh share link."
        case .inviteMalformed:
            return "the link looks broken. ask the inviter to send it again."
        case .iosClaimRelayNotYetWired:
            return "accepting a shared workspace from iphone isn't supported yet. ask the inviter to share through a paired mac."
        default:
            return "something didn't work. ask the inviter to try again."
        }
    }
}

/// Convenience modifier to attach the claw-share sheet to any root
/// view. The sheet is presented automatically whenever the center's
/// state is anything other than `.idle`.
struct ClawShareInvitePresenter: ViewModifier {
    @ObservedObject var center: ClawShareInviteCenter

    func body(content: Content) -> some View {
        content.sheet(isPresented: presentingBinding) {
            ClawShareInviteSheet(center: center)
                .interactiveDismissDisabled(center.isSubmitting)
        }
    }

    private var presentingBinding: Binding<Bool> {
        Binding(
            get: { !isIdle(center.state) },
            set: { newValue in
                if !newValue, !center.isSubmitting {
                    Task { await center.acknowledgeFailure() }
                }
            }
        )
    }

    private func isIdle(_ state: ClawShareRouterState) -> Bool {
        if case .idle = state { return true }
        return false
    }
}

extension View {
    func clawShareInvitePresenter(_ center: ClawShareInviteCenter) -> some View {
        modifier(ClawShareInvitePresenter(center: center))
    }
}
