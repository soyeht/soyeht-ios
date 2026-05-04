import Foundation

// MARK: - Catalog

/// Source of truth for all builtin shortcut bar items.
/// Matches the actual bar built in SoyehtKeyBarView.setupButtons().
/// NOT derived from KeyBarConfiguration (which is missing PgUp/PgDn).
enum ShortcutBarCatalog {

    // MARK: - Builtin Items

    /// All 14 builtin items with correct bytes, group, and style.
    static let allBuiltins: [ShortcutBarItem] = [
        // Navigation group
        ShortcutBarItem(id: "builtin.stab",       label: "S-Tab", kind: .send,        bytes: [0x1B, 0x5B, 0x5A],             group: .navigation, style: .default,  description: "Shift-Tab",             isCustom: false),
        ShortcutBarItem(id: "builtin.slash",       label: "/",     kind: .send,        bytes: [0x2F],                          group: .navigation, style: .default,  description: "Forward slash",         isCustom: false),
        ShortcutBarItem(id: "builtin.tab",         label: "Tab",   kind: .send,        bytes: [0x09],                          group: .navigation, style: .default,  description: "Tab key",               isCustom: false),
        ShortcutBarItem(id: "builtin.esc",         label: "Esc",   kind: .send,        bytes: [0x1B],                          group: .navigation, style: .default,  description: "Escape key",            isCustom: false),
        // Arrows group
        ShortcutBarItem(id: "builtin.arrowUp",     label: "↑",     kind: .arrow,       bytes: [],                              group: .arrows,     style: .default,  description: "Arrow up",              isCustom: false),
        ShortcutBarItem(id: "builtin.arrowDown",   label: "↓",     kind: .arrow,       bytes: [],                              group: .arrows,     style: .default,  description: "Arrow down",            isCustom: false),
        ShortcutBarItem(id: "builtin.arrowLeft",   label: "←",     kind: .arrow,       bytes: [],                              group: .arrows,     style: .default,  description: "Arrow left",            isCustom: false),
        ShortcutBarItem(id: "builtin.arrowRight",  label: "→",     kind: .arrow,       bytes: [],                              group: .arrows,     style: .default,  description: "Arrow right",           isCustom: false),
        // Paging group
        ShortcutBarItem(id: "builtin.pgUp",        label: "PgUp",  kind: .send,        bytes: [0x1B, 0x5B, 0x35, 0x7E],       group: .paging,     style: .default,  description: "Page up",               isCustom: false),
        ShortcutBarItem(id: "builtin.pgDn",        label: "PgDn",  kind: .send,        bytes: [0x1B, 0x5B, 0x36, 0x7E],       group: .paging,     style: .default,  description: "Page down",             isCustom: false),
        // Modifiers group
        ShortcutBarItem(id: "builtin.ctrl",        label: "Ctrl",  kind: .modifierCtrl, bytes: [],                             group: .modifiers,  style: .default,  description: "Control modifier",      isCustom: false),
        ShortcutBarItem(id: "builtin.alt",         label: "Alt",   kind: .modifierAlt,  bytes: [],                             group: .modifiers,  style: .default,  description: "Alt/Meta modifier",     isCustom: false),
        // Actions group
        ShortcutBarItem(id: "builtin.kill",        label: "Kill",  kind: .send,        bytes: [0x03],                          group: .actions,    style: .danger,   description: "Send SIGINT (Ctrl+C)",  isCustom: false),
        ShortcutBarItem(id: "builtin.enter",       label: "Enter", kind: .send,        bytes: [0x0D],                          group: .actions,    style: .action,   description: "Carriage return",       isCustom: false),
    ]

    /// Default bar order — the 14 IDs matching the current hardcoded bar.
    static let defaultBarOrder: [String] = allBuiltins.map(\.id)

    /// Quick lookup: ID → item.
    static let builtinsByID: [String: ShortcutBarItem] = {
        Dictionary(uniqueKeysWithValues: allBuiltins.map { ($0.id, $0) })
    }()

    // MARK: - Popular Shortcuts

    /// Common shortcuts users might want to add.
    static let popularShortcuts: [ShortcutBarItem] = [
        ShortcutBarItem(id: "popular.ctrlC", label: "C-c",  kind: .send, bytes: [0x03], group: .custom, style: .default, description: "Interrupt process",        isCustom: false),
        ShortcutBarItem(id: "popular.ctrlD", label: "C-d",  kind: .send, bytes: [0x04], group: .custom, style: .default, description: "Send EOF / close session", isCustom: false),
        ShortcutBarItem(id: "popular.ctrlZ", label: "C-z",  kind: .send, bytes: [0x1A], group: .custom, style: .default, description: "Suspend process",          isCustom: false),
        ShortcutBarItem(id: "popular.ctrlL", label: "C-l",  kind: .send, bytes: [0x0C], group: .custom, style: .default, description: "Clear screen",             isCustom: false),
        ShortcutBarItem(id: "popular.ctrlA", label: "C-a",  kind: .send, bytes: [0x01], group: .custom, style: .default, description: "Move to line start",       isCustom: false),
        ShortcutBarItem(id: "popular.ctrlW", label: "C-w",  kind: .send, bytes: [0x17], group: .custom, style: .default, description: "Delete word backward",     isCustom: false),
    ]

    /// Quick lookup for popular shortcuts.
    static let popularByID: [String: ShortcutBarItem] = {
        Dictionary(uniqueKeysWithValues: popularShortcuts.map { ($0.id, $0) })
    }()

    // MARK: - Resolve

    /// Resolves an ID to a ShortcutBarItem from builtins, popular, or the given custom list.
    static func resolve(id: String, customItems: [ShortcutBarItem]) -> ShortcutBarItem? {
        if let item = builtinsByID[id] { return item }
        if let item = popularByID[id] { return item }
        return customItems.first { $0.id == id }
    }
}

// MARK: - Workflow Presets

enum WorkflowPreset: String, CaseIterable, Identifiable {
    case tmux
    case vim
    case emacs
    case shell
    case nano
    case gnuScreen
    case ssh
    case docker
    case htop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tmux:      return "tmux"
        case .vim:       return "vim / neovim"
        case .emacs:     return "emacs bindings"
        case .shell:     return "shell / readline"
        case .nano:      return "nano editor"
        case .gnuScreen: return "GNU screen"
        case .ssh:       return "SSH / sysadmin"
        case .docker:    return "docker"
        case .htop:      return "htop / monitoring"
        }
    }

    var icon: String {
        switch self {
        case .tmux:      return "rectangle.split.2x1"
        case .vim:       return "terminal"
        case .emacs:     return "curlybraces"
        case .shell:     return "chevron.right.2"
        case .nano:      return "doc.text"
        case .gnuScreen: return "display"
        case .ssh:       return "shield"
        case .docker:    return "shippingbox"
        case .htop:      return "waveform.path.ecg"
        }
    }

    /// IDs of items in this preset's bar configuration.
    var itemIDs: [String] {
        switch self {
        case .tmux:
            return [
                "builtin.esc", "builtin.tab",
                "builtin.arrowUp", "builtin.arrowDown", "builtin.arrowLeft", "builtin.arrowRight",
                "builtin.ctrl", "builtin.alt",
                "preset.tmux.prefix", "preset.tmux.detach",
                "builtin.kill", "builtin.enter",
            ]
        case .vim:
            return [
                "builtin.esc", "builtin.tab",
                "builtin.arrowUp", "builtin.arrowDown", "builtin.arrowLeft", "builtin.arrowRight",
                "builtin.ctrl",
                "preset.vim.colon",
                "builtin.kill", "builtin.enter",
            ]
        case .emacs:
            return [
                "builtin.esc", "builtin.tab",
                "builtin.ctrl", "builtin.alt",
                "popular.ctrlA", "popular.ctrlW",
                "builtin.kill", "builtin.enter",
            ]
        case .shell:
            return [
                "builtin.tab", "builtin.esc",
                "builtin.arrowUp", "builtin.arrowDown",
                "builtin.ctrl", "builtin.alt",
                "popular.ctrlC", "popular.ctrlD", "popular.ctrlZ",
                "builtin.enter",
            ]
        case .nano:
            return [
                "builtin.esc", "builtin.tab",
                "builtin.arrowUp", "builtin.arrowDown", "builtin.arrowLeft", "builtin.arrowRight",
                "builtin.ctrl",
                "builtin.kill", "builtin.enter",
            ]
        case .gnuScreen:
            return [
                "builtin.esc", "builtin.tab",
                "builtin.arrowUp", "builtin.arrowDown", "builtin.arrowLeft", "builtin.arrowRight",
                "builtin.ctrl",
                "preset.screen.prefix",
                "builtin.kill", "builtin.enter",
            ]
        case .ssh:
            return [
                "builtin.tab", "builtin.esc",
                "builtin.arrowUp", "builtin.arrowDown",
                "builtin.ctrl",
                "popular.ctrlC", "popular.ctrlD",
                "builtin.kill", "builtin.enter",
            ]
        case .docker:
            return [
                "builtin.tab", "builtin.esc",
                "builtin.arrowUp", "builtin.arrowDown",
                "builtin.ctrl",
                "popular.ctrlC", "popular.ctrlD",
                "builtin.enter",
            ]
        case .htop:
            return [
                "builtin.esc",
                "builtin.arrowUp", "builtin.arrowDown", "builtin.arrowLeft", "builtin.arrowRight",
                "builtin.pgUp", "builtin.pgDn",
                "builtin.slash",
                "builtin.kill", "builtin.enter",
            ]
        }
    }

    /// Preset-specific items not in builtins or popular catalog.
    var extraItems: [ShortcutBarItem] {
        switch self {
        case .tmux:
            return [
                ShortcutBarItem(id: "preset.tmux.prefix",  label: "Prefix", kind: .send, bytes: [0x02],       group: .custom, style: .action, description: "tmux prefix (Ctrl+B)", isCustom: false),
                ShortcutBarItem(id: "preset.tmux.detach",  label: "Dtch",   kind: .send, bytes: [0x02, 0x64], group: .custom, style: .action, description: "tmux detach (Prefix+d)", isCustom: false),
            ]
        case .vim:
            return [
                ShortcutBarItem(id: "preset.vim.colon",    label: ":",      kind: .send, bytes: [0x3A],       group: .custom, style: .action, description: "Enter vim command mode", isCustom: false),
            ]
        case .gnuScreen:
            return [
                ShortcutBarItem(id: "preset.screen.prefix", label: "Prefix", kind: .send, bytes: [0x01],      group: .custom, style: .action, description: "screen prefix (Ctrl+A)", isCustom: false),
            ]
        default:
            return []
        }
    }

    var keyCount: Int { itemIDs.count }

    /// Resolves all item IDs to ShortcutBarItems, including preset extras.
    func resolvedItems(customItems: [ShortcutBarItem] = []) -> [ShortcutBarItem] {
        let allExtras = extraItems + customItems
        return itemIDs.compactMap { id in
            ShortcutBarCatalog.resolve(id: id, customItems: allExtras)
        }
    }
}
