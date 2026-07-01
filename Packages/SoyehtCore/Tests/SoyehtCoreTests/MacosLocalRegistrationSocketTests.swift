import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import SoyehtCore

@Suite struct MacosLocalRegistrationSocketTests {
    @Test func pathBuilderUsesShortProfileSeparatedRuntimePath() throws {
        let root = "/tmp/slr-test"
        let prod = MacosLocalRegistrationSocket.path(profile: .release, runtimeRoots: [root])
        let dev = MacosLocalRegistrationSocket.path(profile: .dev, runtimeRoots: [root])

        #expect(prod != dev)
        #expect(prod.hasPrefix("\(root)/soyeht-local-reg-prod-\(Self.currentEUID())/"))
        #expect(dev.hasPrefix("\(root)/soyeht-local-reg-dev-\(Self.currentEUID())/"))
        #expect(prod.hasSuffix("/\(MacosLocalRegistrationSocket.socketName)"))
        #expect(dev.hasSuffix("/\(MacosLocalRegistrationSocket.socketName)"))
        #expect(!prod.contains("Application Support"))
        #expect(dev.utf8.count < MacosLocalRegistrationSocket.macosSunPathLimit)
    }

    @Test func pathBuilderFallsBackWhenRuntimeRootIsTooLong() throws {
        let longRoot = "/tmp/" + String(repeating: "x", count: MacosLocalRegistrationSocket.macosSunPathLimit)
        let dev = MacosLocalRegistrationSocket.path(profile: .dev, runtimeRoots: [longRoot])

        #expect(dev.hasPrefix("/tmp/soyeht-local-reg-dev-\(Self.currentEUID())/"))
        #expect(dev.utf8.count < MacosLocalRegistrationSocket.macosSunPathLimit)
    }

    @Test func validateParentAcceptsPrivateCurrentUserDirectory() throws {
        let parent = try Self.makeParent(mode: 0o700)
        let socketPath = parent.appendingPathComponent(MacosLocalRegistrationSocket.socketName).path

        try MacosLocalRegistrationSocket.validateParent(forSocketPath: socketPath)
    }

    @Test func validateParentRejectsSymlinkParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-local-reg-test-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let socketPath = link.appendingPathComponent(MacosLocalRegistrationSocket.socketName).path

        #expect(throws: BootstrapError.networkDrop) {
            try MacosLocalRegistrationSocket.validateParent(forSocketPath: socketPath)
        }
    }

    @Test func validateParentRejectsGroupOrOtherAccessibleDirectory() throws {
        let parent = try Self.makeParent(mode: 0o755)
        let socketPath = parent.appendingPathComponent(MacosLocalRegistrationSocket.socketName).path

        #expect(throws: BootstrapError.networkDrop) {
            try MacosLocalRegistrationSocket.validateParent(forSocketPath: socketPath)
        }
    }

    @Test func transportValidatesSocketParentBeforeConnecting() throws {
        let parent = try Self.makeParent(mode: 0o755)
        let socketPath = parent.appendingPathComponent(MacosLocalRegistrationSocket.socketName).path
        let request = URLRequest(url: URL(string: "http://soyeht-local/api/v1/health")!)

        #expect(throws: BootstrapError.networkDrop) {
            _ = try UnixDomainSocketHTTPTransaction(socketPath: socketPath, request: request, timeout: 1)
        }
    }

    @Test func sourceGuardsParentOwnerModeAndPreconnectValidation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let socketSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/SoyehtCore/WebAuthn/MacosLocalRegistrationSocket.swift"),
            encoding: .utf8
        )
        let transportSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/SoyehtCore/Networking/UnixDomainSocketHTTPTransport.swift"),
            encoding: .utf8
        )

        #expect(socketSource.contains("metadata.st_uid == geteuid()"))
        #expect(socketSource.contains("mode_t(0o700)"))
        #expect(transportSource.contains("MacosLocalRegistrationSocket.validateParent(forSocketPath: socketPath)"))
    }

    @Test func sourceGuardsSecureUpgradeStrongMintingStop() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtCore/
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // repo root
        let roots = [
            repoRoot.appendingPathComponent("Packages/SoyehtCore/Sources"),
            repoRoot.appendingPathComponent("Sources"),
            repoRoot.appendingPathComponent("TerminalApp/HouseCreatedNotificationService"),
            repoRoot.appendingPathComponent("TerminalApp/Soyeht"),
            repoRoot.appendingPathComponent("TerminalApp/SoyehtLiveActivity"),
            repoRoot.appendingPathComponent("TerminalApp/SoyehtMac"),
        ]
        let standaloneFiles = [
            repoRoot.appendingPathComponent("TerminalApp/main.swift"),
        ]
        let forbidden = [
            "DCAppAttest",
            "DeviceCheck",
            "presence_approved",
            "approval_denied",
            "approved_online",
            "PresenceApproved",
            "ApprovalDenied",
            "ApprovedOnline",
            "presenceApproved",
            "approvalDenied",
            "approvedOnline",
            "SecureUpgradeTranscript.verifyProofCommitments",
            "sign_owner_with_verified_provenance",
            "reviewed-core-v2",
            "reviewed_core_v2",
        ]
        var offenders: [String] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "source guard root must exist as a directory: \(root.path)"
            )
        }
        for file in standaloneFiles {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue,
                "source guard standalone source file must exist: \(file.path)"
            )
        }
        let files = try roots.flatMap(Self.swiftFiles) + standaloneFiles
        #expect(files.count > 0, "source guard must scan product Swift files")
        #expect(
            files.contains { $0.lastPathComponent == "PersonCert.swift" },
            "source guard must include SoyehtCore product sources"
        )
        #expect(
            files.contains { $0.lastPathComponent == "AppDelegate.swift" },
            "source guard must include app product sources"
        )
        #expect(
            files.contains { $0.path.hasSuffix("/TerminalApp/main.swift") },
            "source guard must include the SoyehtMac product entry point"
        )
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                offenders.append("\(relative): \(token)")
            }
        }

        #expect(
            offenders.isEmpty,
            "Secure/Upgrade with iPhone App Attest runtime and explicit approval wire remain STOP-gated; update this guard only with the reviewed proof/signal design. Offending sites: \(offenders)"
        )

        let shippingEntitlements = repoRoot.appendingPathComponent("TerminalApp/Soyeht/Soyeht.entitlements")
        let devEntitlements = repoRoot.appendingPathComponent("TerminalApp/Soyeht/SoyehtDev.entitlements")
        let appAttestEntitlement = "com.apple.developer.devicecheck.appattest-environment"
        let shippingEntitlementsPlist = try Self.plistDictionary(at: shippingEntitlements)
        let devEntitlementsPlist = try Self.plistDictionary(at: devEntitlements)
        #expect(
            shippingEntitlementsPlist[appAttestEntitlement] == nil,
            "shipping Soyeht.entitlements must not carry App Attest until Secure/Upgrade runtime is reviewed"
        )
        #expect(
            devEntitlementsPlist[appAttestEntitlement] as? String == "development",
            "SoyehtDev.entitlements must be the only App Attest capture entitlement and must use the development environment"
        )
    }

    private static func makeParent(mode: Int32) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-local-reg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try parent.path.withCString { path in
            guard chmod(path, mode_t(mode)) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return parent
    }

    private static func currentEUID() -> UInt32 {
        #if canImport(Darwin)
        return geteuid()
        #else
        return 0
        #endif
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }

    private static func plistDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return plist
    }
}
