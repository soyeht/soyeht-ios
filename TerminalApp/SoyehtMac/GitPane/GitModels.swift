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
}

struct GitRepositorySnapshot {
    var repoPath: String
    var branch: String
    var changedFiles: [GitChangedFile]
}
