import Foundation
import Testing
@testable import SoyehtCore

/// The budgets that decide when the phone stops saying "looking" and starts
/// saying something useful. Each case here is a situation the old radar
/// handled by spinning.
@Suite("MacDiscoveryStallClassifier")
struct MacDiscoveryStallClassifierTests {
    private let config = OnboardingConfig.default

    @Test func lookingAtAQuietNetworkBecomesAnAnswerAfterTheHintDelay() {
        let early = MacDiscoveryStallClassifier.classify(
            elapsed: config.macDiscoveryRecoveryHintDelay - 1,
            phase: .looking(sawService: false),
            publisherFailed: false,
            hasTailnet: true
        )
        #expect(early == nil, "under the budget the phone is simply still looking")

        let late = MacDiscoveryStallClassifier.classify(
            elapsed: config.macDiscoveryRecoveryHintDelay,
            phase: .looking(sawService: false),
            publisherFailed: false,
            hasTailnet: true
        )
        #expect(late == .nothingOnNetwork(publisherFailed: false, hasTailnet: true))
    }

    @Test func somethingAdvertisingButNeverResolvingIsADifferentProblem() {
        let stall = MacDiscoveryStallClassifier.classify(
            elapsed: config.macDiscoveryRecoveryHintDelay,
            phase: .looking(sawService: true),
            publisherFailed: false,
            hasTailnet: true
        )
        #expect(stall == .macUnreachable(.txtUnresolved))
    }

    @Test func theOtherBuildsPortIsNamedByItsNumber() {
        let stall = MacDiscoveryStallClassifier.classify(
            elapsed: config.macDiscoveryRecoveryHintDelay,
            phase: .macSeen(observedPort: 8091, matchesProfile: false),
            publisherFailed: false,
            hasTailnet: true
        )
        #expect(stall == .macUnreachable(.portMismatch(
            observed: 8091,
            expected: EndpointPolicy.defaultBootstrapPort()
        )))
    }

    @Test func aMacStillBeingSetUpIsNeverAStall() {
        for elapsed in [0.0, 60.0, 600.0, 3600.0] {
            let stall = MacDiscoveryStallClassifier.classify(
                elapsed: elapsed,
                phase: .waitingForMacSetup(name: "macStudio"),
                publisherFailed: false,
                hasTailnet: true
            )
            #expect(stall == nil, "someone is at the Mac finishing setup; waiting is correct at \(elapsed)s")
        }
    }

    @Test func aNamedMacThatNeverOffersBecomesTheTailscaleConversation() {
        let early = MacDiscoveryStallClassifier.classify(
            elapsed: config.macDiscoveryDeadline - 1,
            phase: .waitingForMacOffer(name: "macStudio"),
            publisherFailed: false,
            hasTailnet: false
        )
        #expect(early == nil)

        let late = MacDiscoveryStallClassifier.classify(
            elapsed: config.macDiscoveryDeadline,
            phase: .waitingForMacOffer(name: "macStudio"),
            publisherFailed: false,
            hasTailnet: false
        )
        #expect(late == .needsTailscale(name: "macStudio"))
    }

    @Test func aPhoneWithSomethingOnScreenIsNeverStalled() {
        let phases: [MacDiscoveryPhase] = [
            .offered(houseName: "Home", hostLabel: "macStudio"),
            .connecting,
            .paired(macName: "macStudio"),
        ]
        for phase in phases {
            #expect(MacDiscoveryStallClassifier.classify(
                elapsed: 9_999,
                phase: phase,
                publisherFailed: false,
                hasTailnet: true
            ) == nil)
            #expect(phase.isWaitingOnItsOwn)
        }
    }

    @Test func aStalledPhaseKnowsItNeedsAPerson() {
        let stalled = MacDiscoveryPhase.stalled(.needsTailscale(name: nil))
        #expect(!stalled.isWaitingOnItsOwn)
    }
}
