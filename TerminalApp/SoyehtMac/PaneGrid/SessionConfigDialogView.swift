import AppKit
import SoyehtCore

/// In-pane "new session" configuration step rendered after the user picks a
/// non-shell agent in `EmptyPaneSessionPickerView`. Mirrors Pencil `RgdJh`:
///
/// - Header `#101010` with green dot + agent name + "· new session" muted +
///   right-side `×` (cancel) button.
/// - Body padding [24, 20] gap 20:
///   - "// project path" label + field row (read-only text + "Choose…" button).
///   - "// git worktree" label + row with NSSwitch + description.
///   - Action row: Cancel / Start buttons.
///
/// The shell / bash path skips this view entirely — `PaneViewController`
/// calls `onStart` immediately with the workspace's resolved bookmark (or
/// the user home dir) and `worktree = false`. This view is only instantiated
/// for interactive agents (claude/codex/hermes).
@MainActor
final class SessionConfigDialogView: NSView {

    // MARK: - Design tokens

    private static let bgFill       = NSColor(srgbRed: 0x0A/255, green: 0x0A/255, blue: 0x0A/255, alpha: 1)
    private static let headerFill   = NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x10/255, alpha: 1)
    private static let headerStroke = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let accentGreen  = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let mutedText    = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let separatorDim = NSColor(srgbRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)
    private static let labelText    = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let fieldBg      = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x0F/255, alpha: 1)
    private static let fieldStroke  = NSColor(srgbRed: 0x2A/255, green: 0x2A/255, blue: 0x2A/255, alpha: 1)
    private static let rowBg        = NSColor(srgbRed: 0x0D/255, green: 0x0D/255, blue: 0x0D/255, alpha: 1)
    private static let rowStroke    = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)
    private static let valueText    = NSColor(srgbRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)
    private static let valueBright  = NSColor(srgbRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    private static let btnIconIdle  = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    var onStart: ((AgentType, URL, Bool) -> Void)?

    // MARK: - State

    private(set) var agent: AgentType = .claw("claude") {
        didSet { agentLabel.stringValue = agent.displayName }
    }
    private(set) var projectURL: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet { pathField.stringValue = projectURL.path; updateWorktreeAvailability() }
    }

    // MARK: - Views

    private let agentLabel = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")
    private let worktreeSwitch = NSSwitch()
    private let worktreeDescription = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start", target: nil, action: nil)

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.bgFill.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Configure

    /// Set the agent + default project URL before showing the dialog.
    func configure(agent: AgentType, defaultURL: URL) {
        self.agent = agent
        self.projectURL = defaultURL
        worktreeSwitch.state = .off
    }

    // MARK: - Layout

    private func buildLayout() {
        let header = makeHeader()
        addSubview(header)

        let pathSection = makePathSection()
        addSubview(pathSection)

        let worktreeSection = makeWorktreeSection()
        addSubview(worktreeSection)

        let btnRow = makeButtonRow()
        addSubview(btnRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),

            pathSection.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            pathSection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            pathSection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            worktreeSection.topAnchor.constraint(equalTo: pathSection.bottomAnchor, constant: 20),
            worktreeSection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            worktreeSection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            btnRow.topAnchor.constraint(greaterThanOrEqualTo: worktreeSection.bottomAnchor, constant: 20),
            btnRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            btnRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            btnRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = Self.headerFill.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let stroke = NSView()
        stroke.wantsLayer = true
        stroke.layer?.backgroundColor = Self.headerStroke.cgColor
        stroke.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stroke)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.accentGreen.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(dot)

        agentLabel.font = Typography.monoNSFont(size: 12, weight: .medium)
        agentLabel.textColor = Self.accentGreen
        agentLabel.stringValue = agent.displayName
        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(agentLabel)

        // Pencil `RgdJh.354qz`: separator is `#3A3A3A` (dim), not the `#6B7280`
        // we use for caption text — it's a visual hairline between values.
        let sep = NSTextField(labelWithString: "·")
        sep.font = Typography.monoNSFont(size: 12, weight: .regular)
        sep.textColor = Self.separatorDim
        sep.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(sep)

        // Pencil `RgdJh.0Jb4e`: "new session" is 11pt (not 12) — sits smaller
        // than the accented agent name to signal it's a secondary label.
        let subtitle = NSTextField(labelWithString: "new session")
        subtitle.font = Typography.monoNSFont(size: 11, weight: .regular)
        subtitle.textColor = Self.mutedText
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(subtitle)

        let closeButton = NSButton()
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleNone
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel new session") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.btnIconIdle]))
            closeButton.image = img.withSymbolConfiguration(cfg)
        }
        closeButton.setAccessibilityLabel("Cancel")
        closeButton.target = self
        closeButton.action = #selector(cancelTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeButton)

        NSLayoutConstraint.activate([
            stroke.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stroke.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stroke.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            stroke.heightAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            agentLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            agentLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            sep.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 8),
            sep.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            subtitle.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 8),
            subtitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        return header
    }

    private func makePathSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Pencil `RgdJh.jsMie`: label is 10pt (smaller than body text) with
        // weight 500 — a tight metadata caption.
        let label = NSTextField(labelWithString: "// project path")
        label.font = Typography.monoNSFont(size: 10, weight: .medium)
        label.textColor = Self.labelText
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        // Pencil `RgdJh.Uafot`: folder icon + path text + spacer + "change"
        // inline link. No separate button bezel — the row itself is the only
        // visible container.
        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = Self.fieldBg.cgColor
        row.layer?.cornerRadius = 6
        row.layer?.borderWidth = 1
        row.layer?.borderColor = Self.fieldStroke.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let folderIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.mutedText]))
            folderIcon.image = img.withSymbolConfiguration(cfg)
        }
        folderIcon.imageScaling = .scaleNone
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(folderIcon)

        pathField.font = Typography.monoNSFont(size: 12, weight: .regular)
        pathField.textColor = Self.valueBright
        pathField.stringValue = projectURL.path
        pathField.isEditable = false
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.lineBreakMode = .byTruncatingHead
        pathField.maximumNumberOfLines = 1
        pathField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(pathField)

        // Pencil `RgdJh.G5ujc`: "change" is plain green inline text, not a
        // boxed button — still clickable, but visually minimal.
        let changeButton = NSButton(title: "change", target: self, action: #selector(chooseTapped))
        changeButton.bezelStyle = .inline
        changeButton.isBordered = false
        changeButton.wantsLayer = true
        changeButton.layer?.backgroundColor = NSColor.clear.cgColor
        changeButton.attributedTitle = NSAttributedString(
            string: "change",
            attributes: [
                .font: Typography.monoNSFont(size: 11, weight: .regular),
                .foregroundColor: Self.accentGreen,
            ]
        )
        changeButton.translatesAutoresizingMaskIntoConstraints = false
        changeButton.setAccessibilityLabel("Change project path")
        row.addSubview(changeButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            row.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 40),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            folderIcon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            folderIcon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 14),
            folderIcon.heightAnchor.constraint(equalToConstant: 14),

            pathField.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 10),
            pathField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: changeButton.leadingAnchor, constant: -10),

            changeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            changeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return container
    }

    private func makeWorktreeSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Pencil `RgdJh.NF7ab`: 10pt caption — matches "// project path".
        let label = NSTextField(labelWithString: "// git worktree")
        label.font = Typography.monoNSFont(size: 10, weight: .medium)
        label.textColor = Self.labelText
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = Self.rowBg.cgColor
        row.layer?.cornerRadius = 6
        row.layer?.borderWidth = 1
        row.layer?.borderColor = Self.rowStroke.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        worktreeSwitch.translatesAutoresizingMaskIntoConstraints = false
        worktreeSwitch.target = self
        worktreeSwitch.action = #selector(worktreeToggled)
        worktreeSwitch.setAccessibilityLabel("Create as git worktree")
        row.addSubview(worktreeSwitch)

        worktreeDescription.font = Typography.monoNSFont(size: 11, weight: .regular)
        worktreeDescription.textColor = Self.valueText
        worktreeDescription.stringValue = "Isolated branch checkout"
        worktreeDescription.maximumNumberOfLines = 1
        worktreeDescription.lineBreakMode = .byTruncatingTail
        worktreeDescription.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(worktreeDescription)

        // Pencil `RgdJh.r5nWg`: git-branch icon on the far right, tinted green
        // to signal this row is a git-aware option.
        let branchIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.accentGreen]))
            branchIcon.image = img.withSymbolConfiguration(cfg)
        }
        branchIcon.imageScaling = .scaleNone
        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(branchIcon)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            row.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 48),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            worktreeSwitch.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            worktreeSwitch.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            worktreeDescription.leadingAnchor.constraint(equalTo: worktreeSwitch.trailingAnchor, constant: 14),
            worktreeDescription.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            worktreeDescription.trailingAnchor.constraint(lessThanOrEqualTo: branchIcon.leadingAnchor, constant: -10),

            branchIcon.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            branchIcon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 14),
            branchIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        updateWorktreeAvailability()
        return container
    }

    private func makeButtonRow() -> NSView {
        // Pencil `RgdJh.HIyrh` uses `justifyContent: end` — buttons hug their
        // content widths and sit flush right, not `fillEqually` stretched
        // across the row. An empty leading spacer pushes them right.
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        let leadingSpacer = NSView()
        leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(leadingSpacer)

        // Pencil `RgdJh.HIyrh`: cancel frame has padding `[8,14]`, lowercase
        // "cancel" label in `#B4B4B4`, framed by `#0F0F0F` fill + `#2A2A2A`
        // stroke — smaller button than a full-width pill.
        let cancel = NSButton(title: "cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .inline
        cancel.isBordered = false
        cancel.wantsLayer = true
        cancel.layer?.backgroundColor = Self.fieldBg.cgColor
        cancel.layer?.borderColor = Self.fieldStroke.cgColor
        cancel.layer?.borderWidth = 1
        cancel.layer?.cornerRadius = 6
        cancel.attributedTitle = NSAttributedString(
            string: "cancel",
            attributes: [
                .font: Typography.monoNSFont(size: 12, weight: .regular),
                .foregroundColor: Self.valueText,
            ]
        )
        cancel.heightAnchor.constraint(equalToConstant: 32).isActive = true

        // Pencil `RgdJh.53YWV`: "start session" lowercase, weight 600, black
        // text on full green fill — primary call-to-action.
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.bezelStyle = .inline
        startButton.isBordered = false
        startButton.wantsLayer = true
        startButton.layer?.backgroundColor = Self.accentGreen.cgColor
        startButton.layer?.cornerRadius = 6
        startButton.attributedTitle = NSAttributedString(
            string: "start session",
            attributes: [
                .font: Typography.monoNSFont(size: 12, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
        )
        startButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        row.addArrangedSubview(cancel)
        row.addArrangedSubview(startButton)
        return row
    }

    // MARK: - Worktree availability

    /// Worktree option is only meaningful inside a git repo. Disable the
    /// switch when the selected path has no `.git` directory.
    private func updateWorktreeAvailability() {
        let gitDir = projectURL.appendingPathComponent(".git")
        let isGitRepo = FileManager.default.fileExists(atPath: gitDir.path)
        worktreeSwitch.isEnabled = isGitRepo
        if !isGitRepo { worktreeSwitch.state = .off }
        worktreeDescription.textColor = isGitRepo ? Self.valueText : Self.mutedText
        worktreeSwitch.toolTip = isGitRepo
            ? nil
            : "Selected folder is not a git repository"
    }

    // MARK: - Actions

    @objc private func cancelTapped() { onCancel?() }

    @objc private func worktreeToggled() {
        // No-op visually; state is read in startTapped.
    }

    @objc private func chooseTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = projectURL
        panel.prompt = "Select"
        panel.message = "Choose the project folder for this session"

        guard let window = self.window else {
            if panel.runModal() == .OK, let picked = panel.url {
                projectURL = picked
            }
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let picked = panel.url else { return }
            self.projectURL = picked
        }
    }

    @objc private func startTapped() {
        onStart?(agent, projectURL, worktreeSwitch.state == .on)
    }
}
