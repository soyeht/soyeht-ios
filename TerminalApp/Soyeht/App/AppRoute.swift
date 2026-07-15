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
}
