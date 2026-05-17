import AppKit

final class EditorTextView: NSTextView {
    var contextProvider: (() -> (String?, String?))?
    var askAgentHandler: ((String, String?, String?) -> Void)?
    var saveHandler: (() -> Void)?
    var closeTabHandler: (() -> Void)?
    var openFileFinderHandler: (() -> Void)?
    var toggleSidebarHandler: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "s" {
            saveHandler?()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "w" {
            closeTabHandler?()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "p" {
            openFileFinderHandler?()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "b" {
            toggleSidebarHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Auto-pair brackets and quotes. Hooks into `insertText` so it composes
    /// with paste, IME, autocomplete, and undo without re-implementing the
    /// text storage write path.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard selectedRange().length == 0,
              let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
              typed.count == 1,
              let scalar = typed.unicodeScalars.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let ch = Character(scalar)
        let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]", "\"": "\"", "'": "'", "`": "`"]
        let closersFromPair = Set(pairs.values)
        let nsText = self.string as NSString
        let caret = selectedRange().location

        if closersFromPair.contains(ch),
           caret < nsText.length,
           Character(nsText.substring(with: NSRange(location: caret, length: 1))) == ch {
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        guard let closing = pairs[ch] else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        if ch == "\"" || ch == "'" || ch == "`" {
            let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            if caret > 0,
               let prevScalar = nsText.substring(with: NSRange(location: caret - 1, length: 1)).unicodeScalars.first,
               wordChars.contains(prevScalar) {
                super.insertText(string, replacementRange: replacementRange)
                return
            }
        }

        super.insertText("\(ch)\(closing)", replacementRange: replacementRange)
        setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0))
    }

    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { super.copy(sender); return }
        let nsText = string as NSString
        let selectedText = nsText.substring(with: sel)
        let (filePath, _) = contextProvider?() ?? (nil, nil)

        let prefix = nsText.substring(to: sel.location)
        let startLine = prefix.components(separatedBy: "\n").count
        let endLine = startLine + selectedText.components(separatedBy: "\n").count - 1
        let lineTag = startLine == endLine ? "L\(startLine)" : "L\(startLine)–\(endLine)"

        let relPath = filePath.map { ($0 as NSString).standardizingPath } ?? ""
        let header = relPath.isEmpty ? "" : "`\(relPath):\(lineTag)`\n\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + selectedText, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        guard selectedRange().length > 0 else { return base }
        let item = NSMenuItem(title: "Ask agent what this does", action: #selector(askAgentAboutSelection(_:)), keyEquivalent: "")
        item.target = self
        base.insertItem(item, at: 0)
        base.insertItem(.separator(), at: 1)
        return base
    }

    @objc private func askAgentAboutSelection(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let selectedText = (string as NSString).substring(with: sel)
        let (filePath, rootPath) = contextProvider?() ?? (nil, nil)
        askAgentHandler?(selectedText, filePath, rootPath)
    }
}
