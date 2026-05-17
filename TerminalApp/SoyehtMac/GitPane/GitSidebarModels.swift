import Foundation

enum GitSidebarSection: CaseIterable, Hashable {
    case staged
    case changes
    case untracked

    var title: String {
        switch self {
        case .staged: return "STAGED CHANGES"
        case .changes: return "CHANGES"
        case .untracked: return "UNTRACKED"
        }
    }

    var scope: GitDiffScope {
        switch self {
        case .staged: return .staged
        case .changes, .untracked: return .unstaged
        }
    }

    var preferStagedBadge: Bool {
        self == .staged
    }

    func files(in snapshot: GitRepositorySnapshot) -> [GitChangedFile] {
        switch self {
        case .staged: return snapshot.stagedFiles
        case .changes: return snapshot.unstagedFiles
        case .untracked: return snapshot.untrackedFiles
        }
    }
}

enum GitSidebarRow {
    case section(GitSidebarSection, count: Int)
    case file(GitChangedFile, GitSidebarSection)
}
