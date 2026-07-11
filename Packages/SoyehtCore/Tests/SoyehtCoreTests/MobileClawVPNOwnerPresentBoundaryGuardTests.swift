#if DEBUG
import Foundation
import Testing

@testable import SoyehtCore

extension MobileClawVPNOwnerPresentBoundaryTests {
    @Test
    func productionActivationFailsClosed() {
        #expect(throws: MobileClawVPNOwnerPresentBoundaryError.invalidResult) {
            try MobileClawVPNOwnerPresentSummary(status: Self.status(productionActivation: true))
        }
    }

    @Test @MainActor
    func contextTupleMismatchFailsBeforeReviewFinishAndMint() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        var mutableContext = binding.approvalContext
        mutableContext.mobileClawVPNExecutionHash = Data(repeating: 0x00, count: 32)
        let mismatchedContext = mutableContext
        let mismatchedBinding = MobileClawVPNOwnerPresentStartBinding(
            execution: binding.execution,
            approvalContext: mismatchedContext
        )
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { context, _ in
                recorder.record("start", context: context)
                return (mismatchedBinding, "prepared")
            },
            finish: { context, _, _ in
                recorder.record("finish", context: context)
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )

        await coordinator.prepare(target: .clawM)

        #expect(coordinator.phase == .failed(canRetry: false))
        #expect(recorder.events == ["start"])
    }

    @Test
    func sourceBoundaryHasNoWireTransportIdentityInputsOrNormalMintFallback() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let boundaryURL = packageRoot.appendingPathComponent(
            "Sources/SoyehtCore/API/MobileClawVPNOwnerPresentBoundary.swift"
        )
        let normalClientURL = packageRoot.appendingPathComponent(
            "Sources/SoyehtCore/API/SoyehtAPIClient+MobileClawVPN.swift"
        )
        let source = try String(contentsOf: boundaryURL, encoding: .utf8)
        let normalClient = try String(contentsOf: normalClientURL, encoding: .utf8)

        #expect(source.contains("struct MobileClawVPNOwnerPresentMintLease: ~Copyable"))
        #expect(source.contains("consuming func consume()"))
        #expect(source.contains("MobileClawVPNOwnerPresentOneShot(<redacted>)"))
        #expect(
            source.components(separatedBy: "MobileClawVPNOwnerPresentMintLease {").count - 1 == 1
        )
        #expect(source.contains("#if DEBUG"))
        #expect(
            !source.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("public ")
            }
        )
        #expect(source.contains("fileprivate init(\n        execution:"))
        #expect(source.components(separatedBy: "try Task.checkCancellation()").count - 1 == 5)
        #expect(!source.contains("SoyehtAPIClient"))
        #expect(!source.contains("mobileClawVPNMintOffer"))
        #expect(!source.contains("ServerContext"))
        #expect(!source.contains("URLRequest"))
        #expect(!source.contains("URLSession"))
        #expect(!source.contains("/api/"))
        #expect(!source.contains("deviceId"))
        #expect(!source.contains("clawId"))
        #expect(!source.contains("Codable"))
        #expect(!source.contains("Hashable"))
        #expect(!source.contains("RawRepresentable"))
        #expect(!normalClient.contains("OwnerPresent"))
    }

    @Test
    func releaseBoundaryHasNoFactoryOrPinnedSessionCallSite() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let boundaryURL = packageRoot.appendingPathComponent(
            "Sources/SoyehtCore/API/MobileClawVPNOwnerPresentBoundary.swift"
        )
        let source = try String(contentsOf: boundaryURL, encoding: .utf8)
        let debugBoundary = try #require(source.range(of: "#if DEBUG"))
        let releaseSource = String(source[..<debugBoundary.lowerBound])
        let debugSource = String(source[debugBoundary.lowerBound...])

        #expect(!releaseSource.contains("MobileClawVPNOwnerPresentCoordinator("))
        #expect(!releaseSource.contains("MobileClawVPNOwnerPresentSession.pinned("))
        #expect(
            debugSource.components(separatedBy: "MobileClawVPNOwnerPresentCoordinator(").count - 1
                == 1
        )
        #expect(
            debugSource.components(separatedBy: "MobileClawVPNOwnerPresentSession.pinned(").count
                - 1 == 1
        )
    }
}
#endif
