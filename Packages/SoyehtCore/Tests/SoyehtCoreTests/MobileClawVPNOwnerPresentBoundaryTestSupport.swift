#if DEBUG
import Foundation

@testable import SoyehtCore

extension MobileClawVPNOwnerPresentBoundaryTests {
    enum TestError: Error {
        case finish
        case responseLost
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _contexts: [String] = []

        func record(_ event: String, context: String) {
            lock.lock()
            _events.append(event)
            _contexts.append(context)
            lock.unlock()
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _events
        }

        var contexts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _contexts
        }

        func count(_ event: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return _events.filter { $0 == event }.count
        }
    }

    actor Gate {
        private var entered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            while !entered {
                await Task.yield()
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    static func binding(
        target: MobileClawVPNOwnerPresentTarget = .clawM
    ) throws -> MobileClawVPNOwnerPresentStartBinding {
        let execution = MobileClawVPNDevE2EExecutionTupleV1(
            householdID: "hh_" + String(repeating: "a", count: 52),
            engineAudience: Data(repeating: 0x90, count: 32),
            memberID: "member-alpha",
            attemptID: "11111111-1111-4111-8111-111111111111",
            readinessRunID: "22222222-2222-4222-8222-222222222222",
            sourceArtifactGitSHA1: Data(repeating: 0xaa, count: 20),
            executionManifestSHA256: Data(repeating: 0xbb, count: 32),
            deviceBinding: Data(repeating: 0xcc, count: 32),
            executionRunID: "33333333-3333-4333-8333-333333333333",
            executionClaimSHA256: Data(repeating: 0xdd, count: 32),
            deviceID: "device-alpha",
            clawID: target == .clawM ? "claw-alpha" : "claw-bravo",
            deviceAlias: "Device-D",
            clawAlias: target.rawValue,
            issuedAt: 1_000,
            expiresAt: 1_060,
            serverNonce: Data(repeating: 0xee, count: 32)
        )
        let context = try OwnerApprovalContextV2.mobileClawVPNDevE2EExecute(
            ownerPersonID: "p_owner-alpha",
            execution: execution,
            replayNonce: Data(repeating: 0xf0, count: 32)
        )
        return MobileClawVPNOwnerPresentStartBinding(
            execution: execution,
            approvalContext: context
        )
    }

    static func status(
        productionActivation: Bool = false
    ) -> MobileClawVPNStatusResponse {
        MobileClawVPNStatusResponse(
            product: "product_a_mobile_claw_vpn",
            mode: "mesh_c_status_only",
            productionActivation: productionActivation,
            state: "configured",
            snapshotPresent: true,
            enrolledDeviceCount: 1,
            availableClawCount: 2,
            grantCount: 2,
            offerCount: 1,
            sessionCount: 1
        )
    }
}
#endif
