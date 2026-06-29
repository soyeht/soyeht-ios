import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Shared macOS local-registration UDS path contract.
///
/// The socket path is transport plumbing only. Authorization still comes from
/// the engine's audit-token + SecCode designated-requirement peer check.
public enum MacosLocalRegistrationSocket {
    public static let socketName = "owner-webauthn.sock"
    public static let macosSunPathLimit = 104

    static let prodNamespace = "soyeht-local-reg-prod"
    static let devNamespace = "soyeht-local-reg-dev"

    public static func path(
        profile: SoyehtInstallProfile = .current,
        runtimeRoots: [String]? = nil
    ) -> String {
        let namespace = profile.kind == .dev ? devNamespace : prodNamespace
        let roots = runtimeRoots ?? defaultRuntimeRoots()
        let candidates = roots + ["/tmp"]
        for root in candidates {
            let parent = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("\(namespace)-\(currentEUID())", isDirectory: true)
            let socketPath = parent.appendingPathComponent(socketName, isDirectory: false).path
            if socketPathFitsMacOS(socketPath) {
                return socketPath
            }
        }
        preconditionFailure("/tmp macOS local registration socket path must fit SUN_LEN")
    }

    public static func validateParent(forSocketPath socketPath: String) throws {
        guard !socketPath.isEmpty else {
            throw BootstrapError.networkDrop
        }
        let parentPath = URL(fileURLWithPath: socketPath, isDirectory: false)
            .deletingLastPathComponent()
            .path
        try validateParentPath(parentPath)
    }

    static func validateParentPath(_ parentPath: String) throws {
        #if canImport(Darwin)
        var metadata = stat()
        guard lstat(parentPath, &metadata) == 0 else {
            throw BootstrapError.networkDrop
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw BootstrapError.networkDrop
        }
        guard metadata.st_uid == geteuid() else {
            throw BootstrapError.networkDrop
        }
        guard (metadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw BootstrapError.networkDrop
        }
        #else
        throw BootstrapError.networkDrop
        #endif
    }

    static func socketPathFitsMacOS(_ path: String) -> Bool {
        path.utf8.count < macosSunPathLimit
    }

    private static func defaultRuntimeRoots() -> [String] {
        var roots: [String] = []
        if let root = darwinUserTempDir() {
            roots.append(root)
        }
        if let root = ProcessInfo.processInfo.environment["TMPDIR"], !root.isEmpty, !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }

    private static func darwinUserTempDir() -> String? {
        #if canImport(Darwin)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard written > 0 else { return nil }
        let raw = String(cString: buffer)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        #else
        return nil
        #endif
    }

    private static func currentEUID() -> UInt32 {
        #if canImport(Darwin)
        return geteuid()
        #else
        return 0
        #endif
    }
}
