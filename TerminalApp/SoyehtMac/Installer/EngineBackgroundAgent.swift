import Foundation

/// Observes engine job presence and supports explicit uninstallation.
/// EngineLifecycleService and its journaled coordinator exclusively own
/// installation/replacement; this helper exposes no install or restart path.
enum EngineBackgroundAgent {

    /// Persistent plist location for this profile. Loading and observing the
    /// job are separate operations; this path alone proves no running service.
    static func installedPlistURL(
        label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    // MARK: - Reading the world

    /// Positive observation only. A false value is not proof of absence;
    /// replacement uses JobPresence so probe errors cannot release a label.
    static func isLoadedInUserDomain(label: String) -> Bool {
        presence(domain: "user", label: label) == .present
    }

    /// Is it still loaded in the graphical session — the domain being left?
    static func isLoadedInGUIDomain(label: String) -> Bool {
        presence(domain: "gui", label: label) == .present
    }

    enum JobPresence: Equatable { case present, absent, unknown }

    static func classifyPresence(_ result: Result, domain: String, label: String, uid: UInt32) -> JobPresence {
        if result.status == 0 { return .present }
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.status == 113,
           lines.contains("Could not find service \"\(label)\" in domain for uid: \(uid)") { return .absent }
        if result.status == 112, domain == "gui",
           lines.contains("Could not find domain for user gui: \(uid)") { return .absent }
        return .unknown
    }

    private static func presence(domain: String, label: String) -> JobPresence {
        classifyPresence(launchctl(["print", "\(domain)/\(getuid())/\(label)"]),
                         domain: domain, label: label, uid: getuid())
    }

    /// Removes the job and the installed plist (uninstall, "start from
    /// scratch"). Deliberately silent about failures: every caller is already
    /// tearing things down and none can act on a partial result.
    static func remove(label: String) {
        _ = launchctl(["bootout", "user/\(getuid())/\(label)"])
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: installedPlistURL(label: label))
    }

    // MARK: - launchctl

    struct Result {
        let status: Int32
        let output: String
    }

    private static func launchctl(_ arguments: [String]) -> Result {
        do {
            let result = try EngineCommandRunner.runBlocking(
                executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments
            )
            if result.timedOut { return Result(status: -1, output: "launchctl timed out; result unconfirmed") }
            if result.outputTruncated { return Result(status: -1, output: "launchctl output exceeded limit") }
            return Result(status: result.status, output: String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
    }
}
