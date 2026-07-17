import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Keeps the pre-runtime data-plane scaffold incapable of starting a tunnel,
/// resolving a route, or moving bytes. A functional slice must update this
/// guard in the same SHA-bound security review that introduces its effect.
@Suite("Mesh data-plane inert boundary")
struct MeshDataPlaneInertBoundaryTests {
    @Test func defaultReadinessIsUnavailableForEveryPurpose() async throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let machineID = try MachineID(authenticatedMachinePublicKey: publicKey)
        let authority = try MachineReachabilityAuthority(
            householdID: "hh_example",
            reportedSelfMachineID: machineID.rawValue,
            authenticatedSelfMachinePublicKey: publicKey
        )
        let readiness = InertMeshTransportReadiness()

        for purpose in MachineReachabilityPurpose.allCases {
            let result = await readiness.readiness(
                authority: authority,
                machineID: machineID,
                purpose: purpose
            )
            #expect(result == .unavailable(.runtimeNotIntegrated))
        }
    }

    @Test func runtimeActivationPreconditionsRemainAtomic() {
        #expect(MeshRuntimeActivationPrecondition.allCases == [
            .authenticatedOrPinnedBaseMeshPublicKeyHex,
            .buildConfigurationScopedAppGroupIsolation,
        ])
    }

    @Test func coreScaffoldHasNoCandidateOrEffectSurface() throws {
        let sources = try inertCoreSources()
        let source = sources.joined(separator: "\n")

        for forbiddenSurface in [
            "URLSession",
            "URLRequest",
            "URLSessionWebSocketTask",
            "NWConnection",
            "NetworkExtension",
            "NETunnelProviderManager",
            "NEPacketTunnel",
            "packetFlow",
            "setTunnelNetworkSettings",
            "readPackets",
            "writePackets",
            "MachineReachabilityCandidate",
            "LegacyStoredEndpointStrategy",
            "EndpointPolicy",
            "ActiveHouseholdState",
            "HouseholdMeshEndpointResolver",
            "VerifiedMeshPeer",
            "DialPermit",
            "SoyehtFerry",
            "ClawShareBridge",
            "UserDefaults",
            "SecItem",
            "FileManager",
        ] {
            #expect(
                !source.contains(forbiddenSurface),
                "inert data-plane scaffold must not introduce \(forbiddenSurface)"
            )
        }

        #expect(source.contains("case unavailable(MeshTransportReadinessUnavailableReason)"))
        #expect(source.contains("case runtimeNotIntegrated"))
        #expect(source.contains(".unavailable(.runtimeNotIntegrated)"))
        #expect(!source.contains("case ready"))
        #expect(!source.contains("func candidates("))
    }

    @Test func packetTunnelProviderRemainsFailClosedBeforeContract() throws {
        let root = try workspaceRoot()
        let providerURL = root.appendingPathComponent(
            "TerminalApp/SoyehtClawShareTunnelProvider/SoyehtClawShareTunnelProvider.swift"
        )
        let provider = try sourceCodeOnly(String(contentsOf: providerURL, encoding: .utf8))

        #expect(provider.contains("completionHandler(TunnelProviderError.notConfigured)"))
        for forbiddenSurface in [
            "setTunnelNetworkSettings",
            "packetFlow",
            "readPackets",
            "writePackets",
            "URLSession",
            "NWConnection",
            "NETunnelProviderManager",
            "MeshTunnelConfigBuilder",
            "providerConfiguration",
            "startVPNTunnel",
            "NEPacketTunnelNetworkSettings",
            "Task {",
        ] {
            #expect(
                !provider.contains(forbiddenSurface),
                "pre-runtime packet provider must not introduce \(forbiddenSurface)"
            )
        }
    }

    private func inertCoreSources() throws -> [String] {
        let meshDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/SoyehtCore/Mesh")
            .standardizedFileURL
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: meshDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { url in
            url.pathExtension == "swift" && url.lastPathComponent.hasPrefix("MeshTransport")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(
            sourceURLs.map(\.lastPathComponent) == ["MeshTransportReadiness.swift"],
            "every MeshTransport source must be explicitly included in this pre-runtime no-effect slice"
        )
        return try sourceURLs.map { try sourceCodeOnly(String(contentsOf: $0, encoding: .utf8)) }
    }

    private func workspaceRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let provider = root.appendingPathComponent(
            "TerminalApp/SoyehtClawShareTunnelProvider/SoyehtClawShareTunnelProvider.swift"
        )
        guard FileManager.default.fileExists(atPath: provider.path) else {
            throw NSError(
                domain: "MeshDataPlaneInertBoundaryTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate packet-tunnel provider from #filePath"]
            )
        }
        return root
    }

    /// Newline-preserving comment stripping prevents a documentation mention
    /// from weakening or accidentally tripping a code-only source ratchet.
    private func sourceCodeOnly(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)

        var index = 0
        var inLineComment = false
        var blockDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append(character)
                }
                index += 1
            } else if blockDepth > 0 {
                if character == "/" && next == "*" {
                    blockDepth += 1
                    index += 2
                } else if character == "*" && next == "/" {
                    blockDepth -= 1
                    index += 2
                } else {
                    if character == "\n" { result.append(character) }
                    index += 1
                }
            } else if character == "/" && next == "/" {
                inLineComment = true
                index += 2
            } else if character == "/" && next == "*" {
                blockDepth += 1
                index += 2
            } else {
                result.append(character)
                index += 1
            }
        }

        return result
    }
}
