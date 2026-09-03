import Foundation

/// What the iPhone is actually doing while it looks for a Mac.
///
/// The radar used to have two states — spinning, and a hint after twenty
/// seconds — for at least six different situations. Worse, one of them was a
/// dead end: when the Mac was still being set up, the phone latched onto
/// "this Mac needs naming" and stopped looking, so once the Mac named itself
/// the phone spun until someone force-quit it.
public enum MacDiscoveryPhase: Equatable, Sendable {
    /// Nothing has answered yet. `sawService` distinguishes "the network is
    /// quiet" from "something is advertising but has not resolved".
    case looking(sawService: Bool)
    /// A service resolved but its port belongs to the other build, or it has
    /// not answered yet.
    case macSeen(observedPort: Int, matchesProfile: Bool)
    /// The engine answered and is still being set up on the Mac. This is the
    /// state that used to be a dead end.
    case waitingForMacSetup(name: String?)
    /// The Mac has a home and is waiting for a phone; the offer is on its way.
    case waitingForMacOffer(name: String?)
    /// The six words are on screen and the person is comparing them.
    case offered(houseName: String, hostLabel: String)
    case connecting
    case paired(macName: String?)
    /// Nothing is going to happen without help. Carries what to say.
    case stalled(MacDiscoveryStall)

    /// Whether this phase is one the phone can leave on its own. A stalled
    /// phone needs the person to do something; every other phase is progress.
    public var isWaitingOnItsOwn: Bool {
        if case .stalled = self { return false }
        return true
    }
}

/// Why the search is not going anywhere, in the terms the screen explains it.
public enum MacDiscoveryStall: Equatable, Sendable {
    /// Nothing is advertising on any network the phone can see.
    case nothingOnNetwork(publisherFailed: Bool, hasTailnet: Bool)
    /// Something answered, but not usefully.
    case macUnreachable(MacUnreachableReason)
    /// The engine is up and named, but the phone cannot reach the pairing
    /// window — the LAN closes once a Mac has a home, so this is the Tailscale
    /// conversation.
    case needsTailscale(name: String?)
}

public enum MacUnreachableReason: Equatable, Sendable {
    /// The Mac is advertising the other build's port. Never phrased as
    /// "dev versus release" on screen — the number is the fact.
    case portMismatch(observed: Int, expected: Int)
    case engineStarting
    case engineTooOld
    case noAnswer(urlErrorCode: Int)
    case txtUnresolved
}

/// Turns elapsed time plus what has been observed into a stall, or nothing.
///
/// Pure on purpose: the budgets are the product's, and they are worth being
/// able to test without a Mac in the room.
public enum MacDiscoveryStallClassifier {
    public static func classify(
        elapsed: TimeInterval,
        phase: MacDiscoveryPhase,
        publisherFailed: Bool,
        hasTailnet: Bool,
        config: OnboardingConfig = .default
    ) -> MacDiscoveryStall? {
        switch phase {
        case .looking(let sawService):
            guard elapsed >= config.macDiscoveryRecoveryHintDelay else { return nil }
            return .nothingOnNetwork(publisherFailed: publisherFailed, hasTailnet: hasTailnet)
                .unless(sawService, then: .macUnreachable(.txtUnresolved))

        case .macSeen(let observedPort, let matchesProfile):
            guard elapsed >= config.macDiscoveryRecoveryHintDelay else { return nil }
            guard matchesProfile else {
                return .macUnreachable(.portMismatch(
                    observed: observedPort,
                    expected: EndpointPolicy.defaultBootstrapPort()
                ))
            }
            return .macUnreachable(.txtUnresolved)

        case .waitingForMacSetup:
            // Someone is at the Mac finishing setup. Waiting is the correct
            // thing to do and there is no deadline on it — the phone used to
            // give up here, or worse, latch and never recover.
            return nil

        case .waitingForMacOffer(let name):
            guard elapsed >= config.macDiscoveryDeadline else { return nil }
            return .needsTailscale(name: name)

        case .offered, .connecting, .paired, .stalled:
            return nil
        }
    }
}

private extension MacDiscoveryStall {
    func unless(_ condition: Bool, then other: MacDiscoveryStall) -> MacDiscoveryStall {
        condition ? other : self
    }
}
