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
}
