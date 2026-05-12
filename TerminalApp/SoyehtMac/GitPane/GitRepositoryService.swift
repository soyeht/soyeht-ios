import Foundation

enum GitRepositoryError: LocalizedError {
    case notRepository(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRepository(let path):
            return "Not a Git repository: \(path)"
        case .commandFailed(let message):
            return message
        }
    }
}

final class GitRepositoryService {
    let repoURL: URL

    init(repoURL: URL) throws {
        self.repoURL = repoURL
        _ = try Self.runGit(["rev-parse", "--show-toplevel"], cwd: repoURL)
    }

    static func resolveRepoRoot(from url: URL) throws -> URL {
        let output = try runGit(["rev-parse", "--show-toplevel"], cwd: url)
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw GitRepositoryError.notRepository(url.path) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func snapshot() throws -> GitRepositorySnapshot {
        let branch = ((try? Self.runGit(["branch", "--show-current"], cwd: repoURL)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try Self.runGit(["status", "--porcelain=v1"], cwd: repoURL)
        let files = status
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseStatusLine(String($0)) }
        return GitRepositorySnapshot(
            repoPath: repoURL.path,
            branch: branch.isEmpty ? "detached HEAD" : branch,
            changedFiles: files
        )
    }

    func diff(path: String?, compareBase: String? = nil) throws -> String {
        if let base = compareBase, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var args = ["diff", "--no-ext-diff", base, "--"]
            if let path, !path.isEmpty { args.append(path) }
            let output = try Self.runGit(args, cwd: repoURL, allowFailure: true)
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No diff against \(base)." : output
        }

        if let path, try isUntracked(path: path) {
            return try untrackedDiff(path: path)
        }

        var args = ["diff", "--no-ext-diff", "--"]
        if let path, !path.isEmpty { args.append(path) }
        let unstaged = try Self.runGit(args, cwd: repoURL, allowFailure: true)

        var stagedArgs = ["diff", "--cached", "--no-ext-diff", "--"]
        if let path, !path.isEmpty { stagedArgs.append(path) }
        let staged = try Self.runGit(stagedArgs, cwd: repoURL, allowFailure: true)
        let combined = [staged, unstaged].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? "No diff for selected file." : combined
    }

    func stage(path: String) throws {
        _ = try Self.runGit(["add", "--", path], cwd: repoURL)
    }

    func unstage(path: String) throws {
        _ = try Self.runGit(["restore", "--staged", "--", path], cwd: repoURL)
    }

    func discard(path: String) throws {
        let status = try Self.runGit(["status", "--porcelain=v1", "--", path], cwd: repoURL)
        if status.hasPrefix("??") {
            _ = try Self.runGit(["clean", "-f", "--", path], cwd: repoURL)
        } else {
            _ = try Self.runGit(["restore", "--", path], cwd: repoURL)
        }
    }

    func commit(message: String) throws {
        _ = try Self.runGit(["commit", "-m", message], cwd: repoURL)
    }

    func push() throws {
        _ = try Self.runGit(["push"], cwd: repoURL)
    }

    func currentHeadSummary() -> String? {
        let output = try? Self.runGit(["status", "-sb"], cwd: repoURL)
        return output?.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    }

    private func isUntracked(path: String) throws -> Bool {
        let status = try Self.runGit(["status", "--porcelain=v1", "--", path], cwd: repoURL)
        return status.hasPrefix("??")
    }

    private func untrackedDiff(path: String) throws -> String {
        let fileURL = repoURL.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return "Untracked directory \(path).\n\nStage it to include its files in the next commit."
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.contains(0),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return "Binary file \(path) is untracked."
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var output = [
            "diff --git a/\(path) b/\(path)",
            "new file mode 100644",
            "index 0000000..0000000",
            "--- /dev/null",
            "+++ b/\(path)",
            "@@ -0,0 +1,\(lines.count) @@",
        ]
        output.append(contentsOf: lines.map { "+\($0)" })
        return output.joined(separator: "\n")
    }

    private func parseStatusLine(_ line: String) -> GitChangedFile? {
        guard line.count >= 3 else { return nil }
        let index = String(line[line.startIndex])
        let workTree = String(line[line.index(after: line.startIndex)])
        let pathStart = line.index(line.startIndex, offsetBy: 3)
        let path = String(line[pathStart...])
        let state: GitChangedFile.State
        if index == "?" && workTree == "?" {
            state = .untracked
        } else if index == "U" || workTree == "U" || (index == "A" && workTree == "A") || (index == "D" && workTree == "D") {
            state = .conflicted
        } else if index != " " {
            state = .staged
        } else {
            state = .unstaged
        }
        return GitChangedFile(path: path, indexStatus: index, workTreeStatus: workTree, state: state)
    }

    @discardableResult
    private static func runGit(_ args: [String], cwd: URL, allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd.path] + args
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 || allowFailure else {
            throw GitRepositoryError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }
}
