import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Security boundary for the mesh transport runtime.
///
/// The RelayStream IpTunnel slice deliberately crosses the former inert
/// ratchet. These assertions pin the reviewed activation/auth/packet surfaces
/// while keeping the general machine-reachability runtime unavailable.
@Suite("Mesh data-plane security boundary")
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

    @Test func packetTunnelRuntimeIsBoundToSignedEphemeralGroupOffer() throws {
        let root = try workspaceRoot()

        // The whole provider directory is in scope, and its file set is PINNED.
        // Reaching two files by hardcoded path left the other two unscanned, so
        // a new file could carry forbidden surface without failing anything.
        // Enumerating plus asserting the exact set makes any added file fail
        // here until it is explicitly reviewed.
        let providerDirectory = root.appendingPathComponent(
            "TerminalApp/SoyehtClawShareTunnelProvider"
        )
        let providerEntries = try FileManager.default.contentsOfDirectory(
            at: providerDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let providerSubdirectories = try providerEntries.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        #expect(
            providerSubdirectories.isEmpty,
            """
            provider sources must remain flat so the boundary cannot miss nested Swift files: \
            \(providerSubdirectories.map(\.lastPathComponent).sorted())
            """
        )
        let providerSourceURLs = providerEntries
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(
            providerSourceURLs.map(\.lastPathComponent) == [
                "NEPacketTunnelFlowAdapter.swift",
                "RelayStreamGuestIPTunnelSessionAdapter.swift",
                "RelayStreamIPTunnelNetworkSettings.swift",
                "SoyehtClawShareTunnelProvider.swift",
            ],
            "every provider source must be explicitly reviewed in this boundary"
        )
        let providerSources: [(name: String, code: String)] = try providerSourceURLs.map {
            (
                name: $0.lastPathComponent,
                code: sourceCodeOnly(try String(contentsOf: $0, encoding: .utf8))
            )
        }

        let providerURL = root.appendingPathComponent(
            "TerminalApp/SoyehtClawShareTunnelProvider/SoyehtClawShareTunnelProvider.swift"
        )
        let provider = try sourceCodeOnly(String(contentsOf: providerURL, encoding: .utf8))
        let networkSettingsURL = root.appendingPathComponent(
            "TerminalApp/SoyehtClawShareTunnelProvider/RelayStreamIPTunnelNetworkSettings.swift"
        )
        let networkSettings = try sourceCodeOnly(
            String(contentsOf: networkSettingsURL, encoding: .utf8)
        )
        let controllerURL = root.appendingPathComponent(
            "TerminalApp/Soyeht/RelayStream/RelayStreamIPTunnelController.swift"
        )
        let controller = try sourceCodeOnly(String(contentsOf: controllerURL, encoding: .utf8))
        let featureFlagsURL = root.appendingPathComponent(
            "Packages/SoyehtCore/Sources/SoyehtCore/Features/SoyehtFeatureFlags.swift"
        )
        let featureFlags = try sourceCodeOnly(
            String(contentsOf: featureFlagsURL, encoding: .utf8)
        )
        let ffiURL = root.appendingPathComponent(
            "Native/RelayStreamGuestFFI/src/lib.rs"
        )
        let ffi = try sourceCodeOnly(String(contentsOf: ffiURL, encoding: .utf8))
        let startOptionsURL = root.appendingPathComponent(
            "Native/RelayStreamGuestFFI/Swift/RelayStreamGuestTunnelStartOptions.swift"
        )
        let startOptionsDocument = try String(contentsOf: startOptionsURL, encoding: .utf8)
        let startOptions = sourceCodeOnly(startOptionsDocument)

        for requiredProviderSurface in [
            "RelayStreamGuestTunnelStartOptions.decode",
            "RelayStreamOfferContract.fromCanonicalBytes",
            "offer.canonicalBytes() == startOptions.offerCbor",
            "verifyRelayStreamIPTunnelGuest",
            "startOptions.authMode == .offerPayload",
            "startOptions.authMaterialCbor == offer.payload.canonicalBytes()",
            "connectPrepared",
            "session.metadata()",
            "metadata.meshIpv4",
            "metadata.meshIpv6 == nil",
            "RelayStreamIPTunnelNetworkSettings.make",
            "setTunnelNetworkSettings",
            "RelayStreamIPPacketPump",
            "packetFlow",
        ] {
            #expect(
                provider.contains(requiredProviderSurface),
                "packet provider must retain reviewed surface \(requiredProviderSurface)"
            )
        }

        for requiredNetworkSettingsSurface in [
            "NEIPv4Settings(",
            "NEIPv4Route(",
            "destinationAddress: networkString",
            "subnetMask: maskString",
            "tunnelRemoteAddress: peerString",
            "ipv4.includedRoutes = [",
        ] {
            #expect(
                networkSettings.contains(requiredNetworkSettingsSurface),
                "packet provider must retain pool-scoped setting \(requiredNetworkSettingsSurface)"
            )
        }
        #expect(!networkSettings.contains("NEIPv4Route.default()"))
        #expect(!networkSettings.contains("NEIPv6Route.default()"))
        #expect(!networkSettings.contains("0.0.0.0"))

        for requiredFFISurface in [
            "TunnelFrame::NetworkSettings(settings)",
            "tokio::time::timeout(timeout, recv_frame(stream))",
            "settings.mtu != auth_mtu",
            "settings.session_id != auth_session_id",
            "\"post-open network settings timed out\"",
            "\"expected post-open network settings\"",
        ] {
            #expect(
                ffi.contains(requiredFFISurface),
                "native client must retain post-Open fail-closed surface \(requiredFFISurface)"
            )
        }

        for forbiddenProviderSurface in [
            "SecureEnclave",
            "SecKey",
            "SecItem",
            "UserDefaults",
            "FileManager",
            "providerConfiguration",
            ".sign(",
        ] {
            // Applied to EVERY enumerated provider source, not just the one
            // reached by path: an adapter can leak a key or persist state as
            // easily as the provider itself.
            for source in providerSources {
                #expect(
                    !source.code.contains(forbiddenProviderSurface),
                    "\(source.name) must not gain host key or persistence surface \(forbiddenProviderSurface)"
                )
            }
        }

        #expect(controller.contains("claimed.guestIdentity.sign(request.signingBytes)"))
        #expect(controller.contains(
            """
            func activate(claimed: ClaimedGroupRelayStreamOffer) async throws {
                    guard SoyehtFeatureFlags.relayStreamIPTunnelActivationEnabled else
            """
        ))
        #expect(controller.contains("ActivationError.activationDisabled"))
        #expect(!controller.contains("mobileClawVPNControlPlaneEnabled"))
        #expect(controller.contains("startVPNTunnel(options:"))
        #expect(controller.contains("installed.first {"))
        #expect(controller.contains("$0.providerBundleIdentifier == providerBundleIdentifier"))
        #expect(controller.contains("\"start_options\": \"ephemeral-only\""))
        #expect(!controller.contains("managers.first ??"))

        #expect(featureFlags.contains(
            "private static let relayStreamIPTunnelActivationDefault = false"
        ))
        #expect(featureFlags.contains(
            """
            if isRelayStreamIPTunnelE2ELaunchArgumentEnabled(
                        bundleIdentifier: Bundle.main.bundleIdentifier,
                        arguments: ProcessInfo.processInfo.arguments
                    )
            """
        ))
        #expect(featureFlags.contains(
            """
            guard debugAssertionsEnabled() else {
                        return relayStreamIPTunnelActivationDefault
            """
        ))
        #expect(featureFlags.contains(
            """
            return e2eDevBundleIdentifiers.contains(bundleIdentifier)
                        && arguments.contains(relayStreamIPTunnelActivationE2ELaunchArgument)
            """
        ))

        #expect(startOptionsDocument.contains("startVPNTunnel(options:)"))
        #expect(startOptionsDocument.contains("must never"))
        #expect(startOptions.contains("static let optionKey"))
        #expect(startOptions.contains("issuedAtUnix"))
        #expect(startOptions.contains("expiresAt"))
        #expect(startOptions.contains("maximumRemainingLifetimeSeconds"))
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
    /// The artifact must attest the repository that OWNS the crate, not only the
    /// vendored protocol source it was compiled against.
    ///
    /// `source_rev` pins theyos and is silent about this repository, so an
    /// artifact built from an uncommitted crate looks clean. This pins the
    /// second producer AND the point at which it is measured: after the bindings
    /// are regenerated and the framework assembled, immediately before the
    /// manifest is written. Measured any earlier, a drifted generated binding
    /// would be stamped clean.
    ///
    /// Read from the shell script with `#` comment lines removed, so a token
    /// mentioned in prose cannot satisfy any assertion below. The two
    /// load-bearing ordering anchors are additionally matched as EXACT trimmed
    /// statements, which closes the remaining gap: a full-line comment is
    /// stripped, but a TRAILING comment is not, so a substring match could
    /// otherwise be fed by `something # status --porcelain`.
    @Test func artifactProvenanceRecordsTheOwningRepositoryAndDirtyState() throws {
        let root = try workspaceRoot()
        let scriptURL = root.appendingPathComponent(
            "Native/RelayStreamGuestFFI/Scripts/build-relay-stream-guest-ffi-xcframework.sh"
        )
        let codeLines = try String(contentsOf: scriptURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let code = codeLines.joined(separator: "\n")

        for required in [
            // The owning repository, fixed — not inferred from a remote.
            "https://github.com/soyeht/soyeht-ios.git",
            // Resolved from Git, at the repository root rather than the crate.
            "rev-parse --show-toplevel",
            "rev-parse HEAD",
            // Untracked files and dirty submodules both count.
            "status --porcelain",
            "--untracked-files=all",
            "--ignore-submodules=none",
            "-dirty",
            // Both fields reach the manifest.
            "\"ffi_source_repo\"",
            "\"ffi_source_rev\"",
            // The vendor provenance is preserved alongside, not replaced.
            "\"source_rev\"",
        ] {
            #expect(
                code.contains(required),
                "artifact provenance must retain \(required) as code, not commentary"
            )
        }

        // ORDER: generation and assembly must precede BOTH measurements, and
        // both measurements must precede the manifest.
        //
        // The two load-bearing points are located by EXACT TRIMMED CODE LINE
        // rather than by substring. A substring match can be satisfied by a
        // trailing comment — `foo # status --porcelain` would hand the ordering
        // check an index that is not the real statement — and these two indices
        // are what the whole ordering argument rests on.
        func firstIndex(of needle: String) throws -> Int {
            let found = codeLines.firstIndex { $0.contains(needle) }
            let index = try #require(found, "script no longer contains \(needle)")
            return index
        }
        func firstIndex(ofExactStatement statement: String) throws -> Int {
            let found = codeLines.firstIndex {
                $0.trimmingCharacters(in: .whitespaces) == statement
            }
            let index = try #require(
                found,
                "script no longer contains the exact statement: \(statement)"
            )
            return index
        }

        let postprocess = try firstIndex(of: "postprocess-uniffi-swift.sh")
        let assemble = try firstIndex(of: "create-xcframework")
        let manifest = try firstIndex(of: "buildinfo.json")
        let revision = try firstIndex(
            ofExactStatement: #"FFI_SOURCE_REV="$(git -C "$FFI_TOPLEVEL" rev-parse HEAD)" || {"#
        )
        let dirtyCheck = try firstIndex(
            ofExactStatement: #"if [[ -n "$(git -C "$FFI_TOPLEVEL" status --porcelain --untracked-files=all --ignore-submodules=none)" ]]; then"#
        )

        #expect(postprocess < revision, "bindings must be refreshed before the revision")
        #expect(assemble < revision, "the framework must be assembled before the revision")
        #expect(postprocess < dirtyCheck, "bindings must be refreshed before the dirty check")
        #expect(assemble < dirtyCheck, "the framework must be assembled before the dirty check")
        #expect(revision < manifest, "the revision must be resolved before the manifest")
        #expect(dirtyCheck < manifest, "dirtiness must be decided before the manifest")
    }

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
