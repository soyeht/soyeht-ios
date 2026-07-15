import Darwin
import Foundation
@testable import SoyehtCore

/// Owns one disposable real-engine process for an integration test.
///
/// The harness never discovers an installed engine. It invokes the repository's
/// pinned `scripts/fetch-engine.sh` into a temporary cache, then points every
/// engine state path at a fresh temporary directory. The client always dials a
/// loopback URL with an ephemeral port.
///
/// theyos 0.1.21 still publishes its household listener to eligible LAN and
/// tailnet interfaces in addition to the loopback address. This helper does
/// not hide that engine-side limitation; see this target's README.
final class EngineHarness {
    enum HarnessError: Error, LocalizedError {
        case repositoryLayoutInvalid
        case fetchFailed(status: Int32)
        case engineBundleIncomplete
        case portAllocationFailed
        case lanBeaconPermissionRequired
        case engineExitedBeforeReady
        case engineDidNotBecomeReady

        var errorDescription: String? {
            switch self {
            case .repositoryLayoutInvalid:
                return "The EngineHarness repository layout could not be resolved."
            case .fetchFailed(let status):
                return "The pinned engine fetch failed with exit status \(status)."
            case .engineBundleIncomplete:
                return "The pinned engine bundle is missing a required executable."
            case .portAllocationFailed:
                return "The EngineHarness could not allocate an ephemeral loopback port."
            case .lanBeaconPermissionRequired:
                return "Real-engine execution requires CI=true or THEYOS_HARNESS_ALLOW_LAN_BEACON=1 because theyos 0.1.21 announces Bonjour beacons on eligible network interfaces. See PR1.1."
            case .engineExitedBeforeReady:
                return "The disposable engine exited before bootstrap became ready."
            case .engineDidNotBecomeReady:
                return "The disposable engine did not become ready before the harness deadline."
            }
        }
    }

    private struct Ports {
        let admin: UInt16
        let household: UInt16
        let caddyHTTP: UInt16
        let caddyHTTPS: UInt16
    }

    private static let requiredEngineExecutables = [
        "theyos-engine",
        "vmrunner_macos_ipc",
        "store-ipc",
        "terminal-ipc",
        "theyos-ssh",
        "theyos-provision-inject",
    ]

    let baseURL: URL
    let stateDirectory: URL

    private let process: Process
    private let logHandle: FileHandle
    private let lifecycleLock = NSLock()
    private var didTearDown = false

    /// A second, explicit interlock is required because the pinned engine
    /// advertises Bonjour services beyond loopback. `THEYOS_HARNESS` enables
    /// this target; CI or the named local opt-in authorizes the real process.
    static var executionBlockReason: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THEYOS_HARNESS"] == "1" else {
            return "Set THEYOS_HARNESS=1 to enable EngineHarnessTests."
        }
        let runningInCI = environment["CI"]?.lowercased() == "true"
        let localBeaconOptIn = environment["THEYOS_HARNESS_ALLOW_LAN_BEACON"] == "1"
        guard runningInCI || localBeaconOptIn else {
            return "Skipped: theyos 0.1.21 may advertise setup/household Bonjour beacons on LAN/tailnet. Run only in CI or explicitly set THEYOS_HARNESS_ALLOW_LAN_BEACON=1; PR1.1 tracks the required hermeticity controls."
        }
        return nil
    }

    private init(
        engineDirectory: URL,
        stateDirectory: URL,
        ports: Ports
    ) throws {
        self.stateDirectory = stateDirectory
        baseURL = URL(string: "http://127.0.0.1:\(ports.household)")!

        let logURL = stateDirectory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: logURL)

        let engine = Process()
        // Process does not expose a pre-exec process-group API. Use the system
        // Perl runtime only as a tiny `setsid` wrapper, then `exec` the pinned
        // binary. Its PID survives exec and becomes a private process-group ID,
        // letting teardown terminate every owned IPC helper with the engine.
        engine.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        engine.arguments = [
            "-MPOSIX=setsid",
            "-e",
            "setsid() or die \"setsid failed: $!\\n\"; exec { $ARGV[0] } @ARGV;",
            engineDirectory.appendingPathComponent("theyos-engine").path,
        ]
        engine.currentDirectoryURL = stateDirectory
        engine.environment = Self.environment(
            engineDirectory: engineDirectory,
            stateDirectory: stateDirectory,
            ports: ports
        )
        engine.standardOutput = logHandle
        engine.standardError = logHandle
        try engine.run()
        process = engine
    }

    deinit {
        tearDown()
    }

    static func boot() async throws -> EngineHarness {
        guard executionBlockReason == nil else {
            throw HarnessError.lanBeaconPermissionRequired
        }
        let engineDirectory = try resolvedEngineDirectory()
        let stateDirectory = try makeStateDirectory()

        do {
            let harness = try EngineHarness(
                engineDirectory: engineDirectory,
                stateDirectory: stateDirectory,
                ports: try allocatePorts()
            )
            do {
                try await harness.waitUntilReady()
                return harness
            } catch {
                harness.tearDown()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: stateDirectory)
            throw error
        }
    }

    /// Stops the child and removes every test state artifact. Safe to call more
    /// than once so XCTest teardown and error-path defers can both own cleanup.
    func tearDown() {
        lifecycleLock.lock()
        guard !didTearDown else {
            lifecycleLock.unlock()
            return
        }
        didTearDown = true
        lifecycleLock.unlock()

        let processGroup = -process.processIdentifier
        if process.processIdentifier > 0 {
            _ = Darwin.kill(processGroup, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning && process.processIdentifier > 0 {
            _ = Darwin.kill(processGroup, SIGKILL)
        }
        if process.isRunning {
            process.waitUntilExit()
        }

        try? logHandle.close()
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(20)
        let statusClient = BootstrapStatusClient(baseURL: baseURL)

        while Date() < deadline {
            do {
                _ = try await statusClient.fetch()
                return
            } catch {
                guard process.isRunning else {
                    throw HarnessError.engineExitedBeforeReady
                }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
        }
        throw HarnessError.engineDidNotBecomeReady
    }

    private static func resolvedEngineDirectory() throws -> URL {
        let root = repositoryRoot()
        let script = root.appendingPathComponent("scripts/fetch-engine.sh")
        let pin = root.appendingPathComponent("scripts/theyos-engine.version")
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let version = pinnedVersion(at: pin) else {
            throw HarnessError.repositoryLayoutInvalid
        }

        // This is an executable cache only, never engine state. Every run still
        // invokes fetch-engine.sh so its sentinel and required-helper checks are
        // authoritative and the test cannot accidentally select an installed
        // user engine.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-engine-harness-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fetch = Process()
        fetch.executableURL = URL(fileURLWithPath: "/bin/bash")
        fetch.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ENGINE_VERSION")
        environment["THEYOS_BUILD_DIR"] = directory.path
        fetch.environment = environment
        fetch.standardOutput = FileHandle.nullDevice
        fetch.standardError = FileHandle.nullDevice
        try fetch.run()
        fetch.waitUntilExit()
        guard fetch.terminationStatus == 0 else {
            throw HarnessError.fetchFailed(status: fetch.terminationStatus)
        }

        guard requiredEngineExecutables.allSatisfy({
            FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
        }) else {
            throw HarnessError.engineBundleIncomplete
        }
        return directory
    }

    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func pinnedVersion(at pin: URL) -> String? {
        guard let contents = try? String(contentsOf: pin, encoding: .utf8) else {
            return nil
        }
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
            .map { String($0) }
    }

    private static func makeStateDirectory() throws -> URL {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-engine-harness-state-\(UUID().uuidString)", isDirectory: true)
        let directories = [
            stateDirectory,
            stateDirectory.appendingPathComponent("home", isDirectory: true),
            stateDirectory.appendingPathComponent("tmp", isDirectory: true),
            stateDirectory.appendingPathComponent("household-state", isDirectory: true),
            stateDirectory.appendingPathComponent("conversations", isDirectory: true),
            stateDirectory.appendingPathComponent("vms", isDirectory: true),
            stateDirectory.appendingPathComponent("snapshots", isDirectory: true),
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return stateDirectory
    }

    private static func environment(
        engineDirectory: URL,
        stateDirectory: URL,
        ports: Ports
    ) -> [String: String] {
        let home = stateDirectory.appendingPathComponent("home")
        let temporary = stateDirectory.appendingPathComponent("tmp")
        let householdState = stateDirectory.appendingPathComponent("household-state")
        let conversations = stateDirectory.appendingPathComponent("conversations")
        let vms = stateDirectory.appendingPathComponent("vms")
        let snapshots = stateDirectory.appendingPathComponent("snapshots")

        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": temporary.path,
            "ADMIN_PORT": String(ports.admin),
            "ADDR": "127.0.0.1:\(ports.admin)",
            "THEYOS_HOUSEHOLD_PORT": String(ports.household),
            "THEYOS_DIR": stateDirectory.path,
            "THEYOS_HOME": stateDirectory.path,
            "THEYOS_STATE_DIR": householdState.path,
            "THEYOS_HOUSEHOLD_STATE_DIR": householdState.path,
            "THEYOS_BIN_DIR": engineDirectory.path,
            "THEYOS_SQLITE_DB": stateDirectory.appendingPathComponent("theyos.db").path,
            "THEYOS_SESSION_DB": stateDirectory.appendingPathComponent("theyos-sessions.db").path,
            "THEYOS_RATELIMIT_DB": stateDirectory.appendingPathComponent("ratelimit.db").path,
            "THEYOS_CONVERSATIONS_DIR": conversations.path,
            "THEYOS_BOOTSTRAP_TOKEN_PATH": stateDirectory.appendingPathComponent("bootstrap-token").path,
            "THEYOS_VM_ASSETS_DIR": vms.path,
            "THEYOS_VM_STATE_DIR": vms.path,
            "THEYOS_SNAPSHOTS_DIR": snapshots.path,
            "THEYOS_VMRUNNER_SOCK": stateDirectory.appendingPathComponent("vmrunner.sock").path,
            "THEYOS_SKIP_LEGACY_MIGRATION": "1",
            "THEYOS_FORCE_SOFTWARE_KEYS": "1",
            "THEYOS_WARM_POOL_SIZE": "0",
            "THEYOS_VMRUNNER_RS_BIN": engineDirectory.appendingPathComponent("vmrunner_macos_ipc").path,
            "THEYOS_STORE_RS_BIN": engineDirectory.appendingPathComponent("store-ipc").path,
            "THEYOS_TERMINAL_RS_BIN": engineDirectory.appendingPathComponent("terminal-ipc").path,
            "THEYOS_SSH_CTL": engineDirectory.appendingPathComponent("theyos-ssh").path,
            "THEYOS_APNS_KEY_PATH": stateDirectory.appendingPathComponent("apns.p8").path,
            "CADDY_HTTP_PORT": String(ports.caddyHTTP),
            "CADDY_HTTPS_PORT": String(ports.caddyHTTPS),
        ]
    }

    private static func allocatePorts() throws -> Ports {
        var values = Set<UInt16>()
        while values.count < 4 {
            values.insert(try allocateLoopbackPort())
        }
        let ports = Array(values)
        return Ports(
            admin: ports[0],
            household: ports[1],
            caddyHTTP: ports[2],
            caddyHTTPS: ports[3]
        )
    }

    private static func allocateLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HarnessError.portAllocationFailed
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else {
            throw HarnessError.portAllocationFailed
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadAddress = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard didReadAddress == 0, address.sin_port != 0 else {
            throw HarnessError.portAllocationFailed
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
