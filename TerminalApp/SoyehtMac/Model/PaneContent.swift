import Foundation

enum PaneContentKind: String, Codable, Hashable {
    case terminal
    case editor
    case git
}

struct TerminalPaneState: Codable, Hashable {
    init() {}
}

struct EditorPaneState: Codable, Hashable {
    var rootPath: String
    var selectedFilePath: String?
    var selectedLine: Int?
    var selectedColumn: Int?
    var openFilePaths: [String]

    init(
        rootPath: String,
        selectedFilePath: String? = nil,
        selectedLine: Int? = nil,
        selectedColumn: Int? = nil,
        openFilePaths: [String] = []
    ) {
        self.rootPath = rootPath
        self.selectedFilePath = selectedFilePath
        self.selectedLine = selectedLine
        self.selectedColumn = selectedColumn
        self.openFilePaths = openFilePaths
    }
}

struct GitPaneState: Codable, Hashable {
    var repoPath: String
    var branch: String?
    var compareBase: String?
    var selectedFilePath: String?

    init(
        repoPath: String,
        branch: String? = nil,
        compareBase: String? = nil,
        selectedFilePath: String? = nil
    ) {
        self.repoPath = repoPath
        self.branch = branch
        self.compareBase = compareBase
        self.selectedFilePath = selectedFilePath
    }
}

enum PaneContent: Codable, Hashable {
    case terminal(TerminalPaneState)
    case editor(EditorPaneState)
    case git(GitPaneState)

    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case editor
        case git
    }

    var kind: PaneContentKind {
        switch self {
        case .terminal:
            return .terminal
        case .editor:
            return .editor
        case .git:
            return .git
        }
    }

    var isTerminal: Bool {
        kind == .terminal
    }

    var displayKind: String {
        switch kind {
        case .terminal:
            return "terminal"
        case .editor:
            return "editor"
        case .git:
            return "git"
        }
    }

    var primaryPath: String? {
        switch self {
        case .terminal:
            return nil
        case .editor(let state):
            return state.selectedFilePath ?? state.rootPath
        case .git(let state):
            return state.repoPath
        }
    }

    var matchingKey: String {
        switch self {
        case .terminal:
            return "terminal"
        case .editor(let state):
            return "editor:\(Self.canonicalPath(state.rootPath))"
        case .git(let state):
            let branch = state.branch ?? ""
            let base = state.compareBase ?? ""
            return "git:\(Self.canonicalPath(state.repoPath)):\(branch):\(base)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(PaneContentKind.self, forKey: .kind) ?? .terminal
        switch kind {
        case .terminal:
            self = .terminal(try container.decodeIfPresent(TerminalPaneState.self, forKey: .terminal) ?? TerminalPaneState())
        case .editor:
            self = .editor(try container.decode(EditorPaneState.self, forKey: .editor))
        case .git:
            self = .git(try container.decode(GitPaneState.self, forKey: .git))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .terminal(let state):
            try container.encode(state, forKey: .terminal)
        case .editor(let state):
            try container.encode(state, forKey: .editor)
        case .git(let state):
            try container.encode(state, forKey: .git)
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return (standardized as NSString).resolvingSymlinksInPath
    }
}
