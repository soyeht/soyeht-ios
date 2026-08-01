import Foundation
import SoyehtCore

enum SoyehtAppRoute {
    case splash
    case qrScanner
    case householdHome(SoyehtIdentitySnapshot)
    case pairingSuccess(SoyehtIdentitySnapshot)
    /// First owner-passkey enrollment ("protect your home"), shown once in
    /// fresh onboarding between pairing success and the recovery message.
    case enrollOwnerPasskey(SoyehtIdentitySnapshot)
    case recoveryMessage(SoyehtIdentitySnapshot)
    case instanceList
    case terminal(wsUrl: String, SoyehtInstance, sessionName: String, context: ServerContext)
    case householdTerminal(
        request: URLRequest,
        SoyehtInstance,
        sessionName: String,
        serverId: String,
        endpoint: URL
    )
    /// Fase 2 attach flow carries `macID`/`paneID` so the terminal view
    /// can refresh the single-use attach nonce via `PairedMacRegistry`
    /// on reconnect. Fase 1 local-handoff QR leaves both nil.
    case localTerminal(wsUrl: String, title: String, macID: UUID?, paneID: String?)
    case relayStreamOpening(ClawShareInvite)
    case relayStreamTerminal(RelayStreamTerminalConfiguration)
    /// A shared claw that serves an app rather than a terminal. Reached from
    /// the same invite flow as `relayStreamTerminal` — which of the two a
    /// claim becomes is decided by the offer's resource, not by the scanner.
    case clawSite(ClawSiteViewModel)
    /// Owner-only: hand one app to someone outside the home. Lives on this
    /// device because minting the invite needs the owner person key, which is
    /// in this phone's Secure Enclave.
    case shareApp(SoyehtIdentitySnapshot)
}
