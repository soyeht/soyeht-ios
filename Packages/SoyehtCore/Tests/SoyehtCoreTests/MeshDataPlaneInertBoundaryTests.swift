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
                "M0bSmokeCheck.swift",
                "NEPacketTunnelFlowAdapter.swift",
                "RelayStreamGuestIPTunnelSessionAdapter.swift",
                "RelayStreamIPTunnelNetworkSettings.swift",
                "SoyehtClawShareTunnelProvider.swift",
            ],
            "every provider source must be explicitly reviewed in this boundary"
        )
        // Forbidden-surface and gate predicates scan the RAW source, never a
        // comment-stripped copy: `sourceCodeOnly` misreads `/*`/`*/` inside a
        // string literal as a comment and can delete real code around it, so a
        // valid `let a = "/*"; <real SecureEnclave use>; let b = "*/"` would
        // vanish from the inspected text — a direct fail-open on an absence
        // predicate (executed mutant during review). Compared
        // with stripping, retaining the raw bytes cannot REMOVE a token match;
        // its only additional error direction is a false RED (a token that
        // appears only in a comment or string), which is the acceptable side
        // for a security guard. Substring scanning is not a claim to catch a
        // semantically-indirect use — only that stripping can't hide a literal
        // one. Both predicates are the shared helpers below, exercised by the
        // production loop AND the self-tests, so a raw→stripped regression in
        // either helper turns a self-test red.
        let providerSources: [(name: String, raw: String)] = try providerSourceURLs.map {
            (name: $0.lastPathComponent, raw: try String(contentsOf: $0, encoding: .utf8))
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

        // M0bSmokeCheck.swift is the reviewed M0b provisioning/keybag canary:
        // a diagnostic whose purpose REQUIRES probing the Keychain
        // accessibility classes, writing a complete-protection App Group file,
        // and recording its result in shared defaults. Those three surfaces
        // are the measurement, not leakage, and the whole file is compiled
        // out of Release — enforced by
        // releaseConfigurationsCarryNoSwiftConditionSetting(), which reads the
        // project's build configurations, so the exemption dies with the
        // gate. Every other surface stays forbidden for it, and every other
        // provider source keeps the full list.
        let debugOnlyDiagnosticAllowance: [String: Set<String>] = [
            "M0bSmokeCheck.swift": ["SecItem", "UserDefaults", "FileManager"],
        ]
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
            // easily as the provider itself. Goes through the SAME helper the
            // self-test drives, so the raw-vs-stripped contract has one
            // implementation to regress.
            for source in providerSources {
                if debugOnlyDiagnosticAllowance[source.name]?
                    .contains(forbiddenProviderSurface) == true {
                    continue
                }
                #expect(
                    !containsForbiddenSurface(raw: source.raw, token: forbiddenProviderSurface),
                    "\(source.name) must not gain host key or persistence surface \(forbiddenProviderSurface)"
                )
            }
        }
        for (exemptedName, allowedSurfaces) in debugOnlyDiagnosticAllowance {
            let exempted = providerSources.first { $0.name == exemptedName }
            #expect(
                exempted != nil,
                "allowance for \(exemptedName) must not outlive the file it exempts"
            )
            guard let exempted else { continue }
            #expect(
                isWhollyDebugGated(exempted.raw),
                "\(exemptedName)'s allowance is contingent on its whole-file #if DEBUG gate"
            )
            // Each allowance entry must correspond to a textual reference to
            // its surface in the file. This is a hygiene check against a STALE
            // allowance — if the file stops mentioning a surface, its entry
            // must be removed, or it silently pre-authorizes reintroducing it.
            // It is TEXTUAL PRESENCE, not proof of use: a diagnostic file we
            // own and DEBUG-gate could hold the token in a string; defending
            // against a deliberate tombstone would need a compiler AST, which
            // is out of proportion for this file's threat model.
            for surface in allowedSurfaces.sorted() {
                #expect(
                    exempted.raw.contains(surface),
                    "\(exemptedName) no longer references \(surface) — remove it from the allowance"
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

    /// The forbidden-surface scan must read raw bytes: a `/*` inside a string
    /// would put a comment stripper into block mode and delete the real
    /// `SecureEnclave` use between the markers, a fail-open. This drives the
    /// SAME `containsForbiddenSurface` helper the production loop uses, so a
    /// regression to strip-then-scan inside the helper turns this red. The
    /// source is valid Swift (`swiftc -parse` rc=0, executed review mutant).
    @Test func forbiddenSurfaceScanReadsRawNotStripped() {
        let commentMarkerHidingRealUse = [
            "#if DEBUG",
            "let a = \"/*\"",
            "let key = SecureEnclave.P256.Signing.PrivateKey()",
            "let b = \"*/\"",
            "#endif",
        ].joined(separator: "\n")
        // The real use is present in the raw bytes → caught.
        #expect(containsForbiddenSurface(raw: commentMarkerHidingRealUse, token: "SecureEnclave"))
        // A token only in a comment is a safe false RED, never a hidden pass.
        #expect(containsForbiddenSurface(raw: "// touches SecKey here", token: "SecKey"))
    }

    /// Self-test of the narrow DEBUG-gate grammar: pass only for a flat
    /// `#if DEBUG` … `#endif` with a token-free body; reject everything else,
    /// including every executed fail-open from the review history. Because the
    /// grammar refuses to model Swift's lexer, a directive token in ANY literal
    /// form (string, raw string, block comment, extended regex) is a safe RED,
    /// not a bypass — the four mutants below all carry a real `#else` in their
    /// Release branch and every one is rejected.
    @Test func debugGateRejectsAnyConditionalTokenInTheBody() {
        // The one shape that passes: mirrors the real M0bSmokeCheck.swift.
        let honest = """
        #if DEBUG
        import Foundation
        enum Canary { static let probe = "SecItem" }
        #endif
        """
        #expect(isWhollyDebugGated(honest))

        // A nested conditional is rejected too — the grammar forbids ANY body
        // token, so the exempted file must stay flat (the real one does).
        let nestedInner = """
        #if DEBUG
        #if targetEnvironment(simulator)
        let sim = true
        #endif
        enum Canary {}
        #endif
        """
        #expect(!isWhollyDebugGated(nestedInner))

        let topLevelElse = """
        #if DEBUG
        enum Canary {}
        #else
        enum Canary { static func persist() {} }
        #endif
        """
        #expect(!isWhollyDebugGated(topLevelElse))

        let closeAndReopen = """
        #if DEBUG
        enum Canary {}
        #endif
        enum Leak {}
        #if DEBUG
        struct Failed: Error {}
        #endif
        """
        #expect(!isWhollyDebugGated(closeAndReopen))

        // Executed fail-open #1 (review): a directive inside a multiline
        // string. The token text is present in the body → RED.
        let q = "\"\"\""
        let stringLiteralWithToken = [
            "#if DEBUG",
            "let banner = \(q)",
            "#if MASK_ONLY",
            q,
            "#else",
            "let trailer = \(q)",
            "#endif",
            q,
            "let leaked = UserDefaults.standard",
            "#endif",
        ].joined(separator: "\n")
        #expect(!isWhollyDebugGated(stringLiteralWithToken))

        // Executed fail-open #2 (review): raw-string escaped delimiter.
        let rawStringWithToken = [
            "#if DEBUG",
            "let banner = #\(q)",
            "\\#\(q)#",
            "#if MASK_ONLY",
            q,
            "\(q)#",
            "#else",
            "let leaked = UserDefaults.standard",
            "#endif",
        ].joined(separator: "\n")
        #expect(!isWhollyDebugGated(rawStringWithToken))

        // Executed fail-open #3 (review): `/*` inside a string puts a
        // comment stripper into block mode. The narrow grammar never strips,
        // so the inner tokens are plainly present → RED. Source compiles rc=0.
        let commentInStringWithToken = [
            "#if DEBUG",
            "let x = \"/*\"",
            "let banner = #\(q)",
            "*/\"",
            "#if MASK_ONLY",
            q,
            "\(q)#",
            "#else",
            "let leaked = UserDefaults.standard",
            "#endif",
        ].joined(separator: "\n")
        #expect(!isWhollyDebugGated(commentInStringWithToken))

        // Executed fail-open #4 (review): extended regex literal
        // `#/ … /#` spans newlines and carries directive text. Source rc=0.
        let regexWithToken = [
            "#if DEBUG",
            "let banner = #/",
            "#if MASK_ONLY",
            "/#",
            "#else",
            "let leaked = UserDefaults.standard",
            "#endif",
        ].joined(separator: "\n")
        #expect(!isWhollyDebugGated(regexWithToken))

        // A block comment can precede a real directive on the same line; the
        // position-independent search still catches it.
        let blockCommentBeforeElse = """
        #if DEBUG
        enum Canary {}
        /* flip */ #else
        enum Leak {}
        #endif
        """
        #expect(!isWhollyDebugGated(blockCommentBeforeElse))

        // Gate-helper raw-vs-stripped regression canary (mirrors the forbidden
        // scan's fixture, executed in review). On the raw predicate the
        // `#else` is plainly in the body → reject. If the helper regressed to
        // strip first, the `/*` in a string and the `*/` in another would put
        // the stripper into block mode and delete the `#else` + the Release
        // body between them, leaving only the outer pair → accept. So this
        // asserting reject turns red the moment the helper stops reading raw.
        // Source is valid Swift (`swift -e` rc=0).
        let strippedRegressionCanary = [
            "#if DEBUG",
            "let a = \"/*\"",
            "#else",
            "let leaked = 1",
            "let b = \"*/\"",
            "#endif",
        ].joined(separator: "\n")
        #expect(!isWhollyDebugGated(strippedRegressionCanary))

        // Structural rejects: content before the gate, and no closing #endif.
        #expect(!isWhollyDebugGated("""
        import Foundation
        #if DEBUG
        enum Canary {}
        #endif
        """))
        #expect(!isWhollyDebugGated("""
        #if DEBUG
        enum Canary {}
        """))

        // Fail-closed trade the narrow grammar accepts: even inert directive
        // text in a string is a RED. Documented so the strictness is a choice.
        #expect(!isWhollyDebugGated("""
        #if DEBUG
        let hint = "#endif is not a directive here"
        #endif
        """))
    }

    /// The M0bSmokeCheck allowance is DEBUG-only by build configuration, so
    /// this boundary holds that gate itself: no Release configuration in the
    /// versioned project may carry a Swift-condition setting AT ALL. The two
    /// settings that can define the Swift DEBUG condition are
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `OTHER_SWIFT_FLAGS` (`-DDEBUG`);
    /// both are forbidden by PRESENCE — the value is never interpreted, which
    /// also catches the `[sdk=…]`-qualified key spelling by the same substring.
    /// Reading the value reopens a grammar every time (multiline lists, a
    /// second sdk-qualified key, `$(VAR)` expansion — all executed bypasses of
    /// value-parsing); forbidding the key's presence closes it, and since no
    /// clean Release carries either key today, any introduction is a real
    /// change that must be reviewed here. Scope: the versioned pbxproj only — a
    /// `-D DEBUG` on the xcodebuild command line is a separate surface, not
    /// covered by this file check. Blocks are sliced marker-to-marker with the
    /// roster frozen at 6/6/6; no Release may carry a `baseConfigurationReference`
    /// (an xcconfig would move the setting out of this file); and the Debug
    /// blocks, which DO carry a condition setting, are the positive control.
    @Test func releaseConfigurationsCarryNoSwiftConditionSetting() throws {
        let pbxproj = try String(
            contentsOf: workspaceRoot()
                .appendingPathComponent("TerminalApp/Soyeht.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        // The appex's own Release configuration must exist by exact identity;
        // losing it (rename, delete) forces this boundary back into review.
        #expect(pbxproj.contains("A2E100000000000000000063 /* Release */ = {"))

        let markers = ["/* Debug */ = {", "/* Dev */ = {", "/* Release */ = {"]
        var starts: [(kind: String, index: String.Index)] = []
        for marker in markers {
            var search = pbxproj.startIndex
            while let found = pbxproj.range(
                of: marker, options: [], range: search..<pbxproj.endIndex
            ) {
                starts.append((kind: marker, index: found.lowerBound))
                search = found.upperBound
            }
        }
        let ordered = starts.sorted { $0.index < $1.index }
        let slices: [(kind: String, body: Substring)] = ordered.enumerated().map {
            position, start in
            let end = position + 1 < ordered.count
                ? ordered[position + 1].index : pbxproj.endIndex
            return (kind: start.kind, body: pbxproj[start.index..<end])
        }

        for marker in markers {
            #expect(
                slices.filter { $0.kind == marker }.count == 6,
                "configuration roster moved for \(marker) — re-review this boundary"
            )
        }

        for slice in slices where slice.kind == "/* Release */ = {" {
            #expect(
                !carriesSwiftConditionSetting(slice.body),
                "a Release configuration carries a Swift-condition setting — it could ship the M0b allowance live; review it here"
            )
            #expect(
                !slice.body.contains("baseConfigurationReference"),
                "a Release configuration points at an xcconfig — the condition could move out of the pbxproj; resolve or pin it"
            )
        }
        // Positive control: the predicate must fire where a condition setting
        // IS present, or the sweep above is measuring nothing.
        #expect(
            slices.contains {
                $0.kind == "/* Debug */ = {" && carriesSwiftConditionSetting($0.body)
            }
        )
    }

    /// Presence canaries: each way a Release could reintroduce a Swift-condition
    /// setting must trip the predicate REGARDLESS of value — the plain key, the
    /// `[sdk=…]`-qualified key, and `OTHER_SWIFT_FLAGS` even when its value is a
    /// `$(VAR)` expansion that hides DEBUG (both executed bypasses of a value
    /// scan). A block carrying neither key must NOT trip it, or the boundary
    /// false-reds the clean tree.
    @Test func swiftConditionSettingPredicateForbidsBothKeysByPresence() {
        #expect(carriesSwiftConditionSetting(
            "{\n\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n}"[...]))
        #expect(carriesSwiftConditionSetting(
            "{\n\t\"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]\" = DEBUG;\n}"[...]))
        #expect(carriesSwiftConditionSetting(
            "{\n\tOTHER_SWIFT_FLAGS = \"$(M0B_RELEASE_FLAGS)\";\n}"[...]))
        #expect(!carriesSwiftConditionSetting(
            "{\n\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n\tMTL_ENABLE_DEBUG_INFO = NO;\n}"[...]))
    }

    /// True if a configuration block carries either Swift-condition setting,
    /// in any spelling (plain or `[sdk=…]`-qualified). Presence only; the
    /// value is deliberately not read — see the boundary test's rationale.
    func carriesSwiftConditionSetting(_ block: Substring) -> Bool {
        block.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS")
            || block.contains("OTHER_SWIFT_FLAGS")
    }

    /// The forbidden-surface predicate, factored so the production loop and
    /// the self-test share ONE implementation: a raw-vs-stripped regression
    /// has a single place to happen and a self-test that catches it. Scans the
    /// raw source — stripping could delete a real use around a `/*` inside a
    /// string (executed mutant), a fail-open; raw can only false-RED.
    func containsForbiddenSurface(raw: String, token: String) -> Bool {
        raw.contains(token)
    }

    /// A file qualifies for the DEBUG-only allowance only if it is one flat
    /// `#if DEBUG` … `#endif` region with NO conditional-compilation token in
    /// the body. Deliberately narrow: rather than model Swift's lexer — which
    /// carries directive-shaped text through string, raw-string, block-comment
    /// and extended-regex (`#/…/#`) literals, each an executed fail-open in a
    /// prior revision — it rejects ANY occurrence of `#if`/`#elseif`/`#else`/
    /// `#endif` in the raw body. A directive token buried in a literal is a
    /// safe false RED, never a fabricated balance; the checker cannot be
    /// tricked into passing something it should reject, only into rejecting
    /// something exotic it could accept, and for a single hand-audited
    /// diagnostic that is the right trade.
    ///
    /// Measured against the one exempted file, whose body carries zero such
    /// tokens (executed in review). If it ever needs a nested
    /// conditional, this goes red and forces the allowance to be re-reviewed.
    ///
    /// Token search is position-independent, not first-non-blank: Swift accepts
    /// `/* comment */ #else` as a real directive, so a token anywhere on a body
    /// line counts.
    func isWhollyDebugGated(_ rawSource: String) -> Bool {
        let nonEmpty = rawSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard nonEmpty.count >= 2,
              nonEmpty.first == "#if DEBUG",
              nonEmpty.last == "#endif"
        else {
            return false
        }
        let conditionalTokens = ["#if", "#elseif", "#else", "#endif"]
        for line in nonEmpty.dropFirst().dropLast() {
            if conditionalTokens.contains(where: line.contains) {
                return false
            }
        }
        return true
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
