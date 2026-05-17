import Foundation

struct GitChangedFile: Hashable {
    enum State: String {
        case staged
        case unstaged
        case untracked
        case conflicted
    }

    var path: String
    var indexStatus: String
    var workTreeStatus: String
    var state: State

    var isUntracked: Bool {
        indexStatus == "?" && workTreeStatus == "?"
    }

    var isConflicted: Bool {
        state == .conflicted
    }

    var hasStagedChanges: Bool {
        !isUntracked && indexStatus != " "
    }

    var hasUnstagedChanges: Bool {
        !isUntracked && workTreeStatus != " "
    }

    var canStage: Bool {
        isUntracked || hasUnstagedChanges || isConflicted
    }

    var canUnstage: Bool {
        hasStagedChanges
    }

    var canDiscard: Bool {
        isUntracked || hasUnstagedChanges
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    var parentDisplayPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? "/" : parent
    }

    func badgeText(preferStaged: Bool = false) -> String {
        if isUntracked { return "U" }
        if isConflicted { return "!" }
        let status = preferStaged ? indexStatus : workTreeStatus
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return indexStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "M" : indexStatus
        }
        return status
    }
}

enum GitDiffScope: Equatable {
    case combined
    case staged
    case unstaged
}

struct GitDiffStats {
    var additions: Int
    var deletions: Int

    static let empty = GitDiffStats(additions: 0, deletions: 0)
}

struct GitWorktree: Hashable {
    var path: String
    var branch: String?
    var head: String?
    var isBare: Bool
    var isCurrent: Bool

    var displayName: String {
        URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    var displayBranch: String {
        branch ?? "detached"
    }
}

struct GitRepositorySnapshot {
    var repoPath: String
    var branch: String
    var upstream: String?
    var ahead: Int
    var behind: Int
    var localBranches: [String]
    var worktrees: [GitWorktree]
    var changedFiles: [GitChangedFile]

    var branchSyncSummary: String {
        guard upstream != nil else { return "no upstream" }
        return "↑ \(ahead)  ↓ \(behind)"
    }

    var stagedFiles: [GitChangedFile] {
        changedFiles.filter { $0.hasStagedChanges }
    }

    var unstagedFiles: [GitChangedFile] {
        changedFiles.filter { $0.hasUnstagedChanges && !$0.isUntracked }
    }

    var untrackedFiles: [GitChangedFile] {
        changedFiles.filter(\.isUntracked)
    }
}
