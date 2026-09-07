import CryptoKit
import Foundation
import SoyehtCore

/// Validates and stages package bytes under the lifecycle journal lock.
/// EngineLifecycleService owns preparation order and all activation decisions.
enum EnginePackager {

    // MARK: - Paths

    static let soyehtSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        // "Soyeht" for the shipping app, "SoyehtDev" for the developer build —
        // the dev engine binaries/token live in a separate tree.
        return appSupport.appendingPathComponent(
            SoyehtInstallProfile.current.supportDirectoryName,
            isDirectory: true
        )
    }()

    static let engineDestinationDirectory: URL =
        soyehtSupportDirectory.appendingPathComponent("engine", isDirectory: true)

    static let engineDestinationURL: URL =
        engineDestinationDirectory.appendingPathComponent("theyos-engine")

    private static let supportBinaryNames = EmbeddedEngineSupportBundleSpec.supportBinaryNames

    static let bootstrapTokenURL: URL =
        soyehtSupportDirectory.appendingPathComponent("bootstrap-token")

    static let logsDirectory: URL =
        soyehtSupportDirectory.appendingPathComponent("logs", isDirectory: true)

    // MARK: - Public API

    /// The production lifecycle adapter uses its already-held exclusive
    /// journal. A pending target is immutable even if a newer app has arrived.
    static func stage(holding journal: EngineReplacementJournal) throws {
        guard try journal.read() == nil else { throw EngineReplacementJournal.Failure.busy }
        _ = try validatedBundledArtifact()
        try installSupportBinaries()
        try installBootstrapToken()
    }

    /// Validate the complete package and the engine/helper wire contract
    /// before replacing any installed executable. Matching a cache version
    /// string cannot make a package without a supervisor usable.
    static func validatedBundledArtifact() throws -> EngineArtifactIdentity {
        _ = try EmbeddedEngineBundleProbe().validateBundledSupport()
        return try validatedArtifact(in: bundledSupportBinaryURL(named: "theyos-engine").deletingLastPathComponent())
    }

    static func validatedArtifact(in directory: URL) throws -> EngineArtifactIdentity {
        // Never execute a candidate engine to discover its CLI contract: an
        // older engine may ignore an unknown option and start the service.
        // Delivery must supply metadata bound to the exact executable bytes.
        let executable = directory.appendingPathComponent("theyos-engine")
        let metadataURL = executable.deletingLastPathComponent().appendingPathComponent(EmbeddedEngineHelpers.artifactReceiptName)
        struct ArtifactReceipt: Decodable {
            let artifact: EngineArtifactIdentity
            let executable_sha256: String
        }
        guard let data = try? Data(contentsOf: metadataURL),
              let receipt = try? JSONDecoder().decode(ArtifactReceipt.self, from: data),
              let digest = sha256(executable),
              digest.map({ String(format: "%02x", $0) }).joined() == receipt.executable_sha256 else {
            throw EnginePackagerError.incompatiblePackage
        }
        guard let diskUUID = try EngineMachOIdentity.imageUUID(at: executable),
              diskUUID == receipt.artifact.imageUUID else {
            throw EnginePackagerError.incompatiblePackage
        }
        let helper = try EngineCommandRunner.runBlocking(
            executable: directory.appendingPathComponent("soyeht-ptyd"), arguments: ["--contract"])
        struct Contract: Decodable { let protocol_version: UInt16 }
        let identity = receipt.artifact
        guard helper.succeeded,
              let contract = try? JSONDecoder().decode(Contract.self, from: helper.output),
              identity.ptySupervisorProtocol == contract.protocol_version else {
            throw EnginePackagerError.incompatiblePackage
        }
        return identity
    }

    // MARK: - Private

    private static func installSupportBinaries() throws {
        try FileManager.default.createDirectory(
            at: engineDestinationDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )

        for binaryName in supportBinaryNames {
            let sourceURL = try bundledSupportBinaryURL(named: binaryName)
            let destinationURL = engineDestinationDirectory.appendingPathComponent(binaryName)
            try installBinary(named: binaryName, sourceURL: sourceURL, destinationURL: destinationURL)
        }
        let receiptName = EmbeddedEngineHelpers.artifactReceiptName
        let receipt = try bundledSupportBinaryURL(named: "theyos-engine")
            .deletingLastPathComponent().appendingPathComponent(receiptName)
        try Data(contentsOf: receipt).write(to: engineDestinationDirectory.appendingPathComponent(receiptName), options: .atomic)
    }

    private static func installBootstrapToken() throws {
        try FileManager.default.createDirectory(
            at: soyehtSupportDirectory,
            withIntermediateDirectories: true
        )

        if let existing = try? String(contentsOf: bootstrapTokenURL, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try setPrivateFilePermissions(bootstrapTokenURL)
            return
        }

        let key = SymmetricKey(size: .bits256)
        let tokenData = key.withUnsafeBytes { Data($0) }
        let token = tokenData.base64EncodedString()

        try token.write(to: bootstrapTokenURL, atomically: true, encoding: .utf8)
        try setPrivateFilePermissions(bootstrapTokenURL)
    }

    private static func installBinary(named binaryName: String, sourceURL: URL, destinationURL: URL) throws {
        guard !isUpToDate(source: sourceURL, destination: destinationURL) else { return }
        try EngineBinaryStaging.stage(source: sourceURL, destination: destinationURL)
    }

    private static func setPrivateFilePermissions(_ url: URL) throws {
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        attrs[.posixPermissions] = NSNumber(value: 0o600 as Int16)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    private static func bundledSupportBinaryURL(named binaryName: String) throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(binaryName)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EnginePackagerError.supportBinaryNotFound(binaryName)
        }
        return url
    }

    private static func isUpToDate(source: URL, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard
            let srcSize = (try? source.resourceValues(forKeys: keys))?.fileSize,
            let dstSize = (try? destination.resourceValues(forKeys: keys))?.fileSize,
            srcSize == dstSize
        else { return false }

        guard let sourceDigest = sha256(source),
              let destinationDigest = sha256(destination) else {
            return false
        }
        return sourceDigest == destinationDigest
    }

    private static func sha256(_ url: URL) -> SHA256.Digest? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data)
    }
}

enum EnginePackagerError: Error, LocalizedError {
    case supportBinaryNotFound(String)
    case incompatiblePackage

    var errorDescription: String? {
        switch self {
        case .supportBinaryNotFound(let binaryName):
            return "Support binary missing from app bundle (Contents/Helpers/\(binaryName))."
        case .incompatiblePackage:
            return String(localized: LocalizedStringResource(
                "engine.install.incompatiblePackage",
                defaultValue: "The bundled engine and terminal supervisor could not be verified as compatible.",
                comment: "Package validation failed before replacing an installed engine."
            ))
        }
    }
}
