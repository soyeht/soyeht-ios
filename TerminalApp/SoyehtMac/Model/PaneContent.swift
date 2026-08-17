import Foundation

enum PaneContentKind: String, Codable, Hashable {
    case terminal
    case editor
    case git
    case web
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
    var isProjectExpanded: Bool

    init(
        rootPath: String,
        selectedFilePath: String? = nil,
        selectedLine: Int? = nil,
        selectedColumn: Int? = nil,
        openFilePaths: [String] = [],
        isProjectExpanded: Bool = true
    ) {
        self.rootPath = rootPath
        self.selectedFilePath = selectedFilePath
        self.selectedLine = selectedLine
        self.selectedColumn = selectedColumn
        self.openFilePaths = openFilePaths
        self.isProjectExpanded = isProjectExpanded
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath
        case selectedFilePath
        case selectedLine
        case selectedColumn
        case openFilePaths
        case isProjectExpanded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        selectedFilePath = try container.decodeIfPresent(String.self, forKey: .selectedFilePath)
        selectedLine = try container.decodeIfPresent(Int.self, forKey: .selectedLine)
        selectedColumn = try container.decodeIfPresent(Int.self, forKey: .selectedColumn)
        openFilePaths = try container.decodeIfPresent([String].self, forKey: .openFilePaths) ?? []
        isProjectExpanded = try container.decodeIfPresent(Bool.self, forKey: .isProjectExpanded) ?? true
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

/// Web-pane Phase 1 state. Identity and current page are SEPARATE fields
/// (review correction, docs/web-pane-phase1.md §"Por que anchorURL"):
/// `installSpecialContent` only reuses an existing view controller when
/// `matchingKey` matches, and `matchingKey` derives from `anchorURL` —
/// which is immutable after creation. The current `url` may drift on every
/// main-frame navigation; that must NOT change identity, or each navigation
/// would tear down and reload the WKWebView (losing scroll/form/history).
struct WebPaneState: Codable, Hashable {
    /// Immutable after creation. Defines `matchingKey` (pane dedupe/reuse).
    var anchorURL: String
    /// Current page. Written back on main-frame navigation; drives restore.
    var url: String
    /// Last known page title (pane header).
    var title: String?

    init(anchorURL: String, url: String? = nil, title: String? = nil) {
        self.anchorURL = anchorURL
        self.url = url ?? anchorURL
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case anchorURL, url, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anchorURL = try container.decode(String.self, forKey: .anchorURL)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? anchorURL
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

enum PaneContent: Codable, Hashable {
    case terminal(TerminalPaneState)
    case editor(EditorPaneState)
    case git(GitPaneState)
    case web(WebPaneState)

    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case editor
        case git
        case web
    }

    var kind: PaneContentKind {
        switch self {
        case .terminal:
            return .terminal
        case .editor:
            return .editor
        case .git:
            return .git
        case .web:
            return .web
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
        case .web:
            return "web"
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
        case .web:
            // A URL is not a file path; `primaryPath` feeds reporting fields
            // (e.g. `working_directory`) where a URL would be wrong data.
            return nil
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
        case .web(let state):
            return "web:\(WebURL.canonical(state.anchorURL))"
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
        case .web:
            self = .web(try container.decode(WebPaneState.self, forKey: .web))
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
        case .web(let state):
            try container.encode(state, forKey: .web)
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return (standardized as NSString).resolvingSymlinksInPath
    }
}
