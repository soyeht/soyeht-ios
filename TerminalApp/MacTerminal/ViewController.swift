//
//  ViewController.swift
//  MacTerminal
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import SwiftTerm
import SoyehtCore
import UniformTypeIdentifiers

// MARK: - Scroll-aware local terminal view

/// LocalProcessTerminalView subclass that forwards scroll events to the PTY when
/// the running process has requested mouse mode (e.g. tmux with `set -g mouse on`).
/// When mouse mode is off, falls back to SwiftTerm's buffer scroll (normal behavior).
class SoyehtLocalTerminalView: LocalProcessTerminalView {
    override func scrollWheel(with event: NSEvent) {
        let t = getTerminal()
        if allowMouseReporting && t.mouseMode != .off {
            // Convert scroll delta to SGR button codes: 64 = wheel-up, 65 = wheel-down
            let button = event.deltaY > 0 ? 64 : 65
            let cellW = max(1.0, frame.width  / CGFloat(t.cols))
            let cellH = max(1.0, frame.height / CGFloat(t.rows))
            let pt  = convert(event.locationInWindow, from: nil)
            let col = max(1, min(Int(pt.x / cellW) + 1, t.cols))
            let row = max(1, min(Int((frame.height - pt.y) / cellH) + 1, t.rows))
            // Send SGR press only — scroll wheel has no "release" event
            send(txt: "\u{1b}[<\(button);\(col);\(row)M")
        } else {
            super.scrollWheel(with: event)
        }
    }
}

class LocalShellViewController: NSViewController, LocalProcessTerminalViewDelegate, NSUserInterfaceValidations {
    @IBOutlet var loggingMenuItem: NSMenuItem?

    var changingSize = false
    var logging: Bool = false
    var zoomGesture: NSMagnificationGestureRecognizer?
    var postedTitle: String = ""
    var postedDirectory: String? = nil
    private var keyEventMonitor: Any?
    
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        if changingSize {
            return
        }
        changingSize = true
        //var border = view.window!.frame - view.frame
        var newFrame = terminal.getOptimalFrameSize ()
        let windowFrame = view.window!.frame
        
        newFrame = CGRect (x: windowFrame.minX, y: windowFrame.minY, width: newFrame.width, height: windowFrame.height - view.frame.height + newFrame.height)

        view.window?.setFrame(newFrame, display: true, animate: true)
        changingSize = false
    }
    
    func updateWindowTitle ()
    {
        var newTitle: String
        if let dir = postedDirectory {
            if let uri = URL(string: dir) {
                if postedTitle == "" {
                    newTitle = uri.path
                } else {
                    newTitle = "\(postedTitle) - \(uri.path)"
                }
            } else {
                newTitle = postedTitle
            }
        } else {
            newTitle = postedTitle
        }
        view.window?.title = newTitle
    }
    
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        updateWindowTitle ()
    }
    
    func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?) {
        self.postedDirectory = directory
        updateWindowTitle()
    }
    
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        view.window?.close()
        if let e = exitCode {
            print ("Process terminated with code: \(e)")
        } else {
            print ("Process vanished")
        }
    }
    var terminal: SoyehtLocalTerminalView!

    static weak var lastTerminal: LocalProcessTerminalView!
    
    func getBufferAsData () -> Data
    {
        return terminal.getTerminal().getBufferAsData ()
    }
    
    func updateLogging ()
    {
//        let path = logging ? "/Users/miguel/Downloads/Logs" : nil
//        terminal.setHostLogging (directory: path)
        NSUserDefaultsController.shared.defaults.set (logging, forKey: "LogHostOutput")
    }
    
    // Returns the shell associated with the current account
    func getShell () -> String
    {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/bash"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer {
            buffer.deallocate()
        }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)
        
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
            return "/bin/bash"
        }
        return String (cString: pwd.pw_shell)
    }
    
    class TD: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {
        }
        
        
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        terminal = SoyehtLocalTerminalView(frame: view.frame)
        terminal.metalBufferingMode = .perFrameAggregated
        do {
            try terminal.setUseMetal(false)
        } catch {
            print("METAL DISABLED: \(error)")
        }
        applyAppearance()
        terminal.getTerminal().setCursorStyle(.steadyBlock)
        zoomGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(zoomGestureHandler))
        terminal.addGestureRecognizer(zoomGesture!)
        LocalShellViewController.lastTerminal = terminal
        terminal.processDelegate = self

        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent
        
        FileManager.default.changeCurrentDirectoryPath (FileManager.default.homeDirectoryForCurrentUser.path)
        terminal.startProcess (executable: shell, execName: shellIdiom)
        view.addSubview(terminal)
        logging = NSUserDefaultsController.shared.defaults.bool(forKey: "LogHostOutput")
        updateLogging ()

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: .preferencesDidChange, object: nil)
        // Re-focus the terminal whenever this tab's window becomes the key window.
        // viewDidAppear fires only once; NSWindow.didBecomeKeyNotification fires on every tab click.
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)

        // Support --cmd "command" launch argument for automation/profiling
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--cmd"), idx + 1 < args.count {
            let command = args[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let cmdLine = command + "\n"
                let bytes = Array(cmdLine.utf8)
                self.terminal.send(source: self.terminal, data: bytes[...])
            }
        }

        #if DEBUG_MOUSE_FOCUS
        var t = NSTextField(frame: NSRect (x: 0, y: 100, width: 200, height: 30))
        t.backgroundColor = NSColor.white
        t.stringValue = "Hello - here to test focus switching"
        
        view.addSubview(t)
        #endif
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        // Give the terminal first-responder status so key events land here
        view.window?.makeFirstResponder(terminal)
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyMonitor()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        // Only act when the notification is for our own window (not another window becoming key)
        guard let w = note.object as? NSWindow, w === view.window else { return }
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: - Tmux Keyboard Shortcuts (local shell)
    //
    // Same shortcut map as the web terminal and MacOSWebSocketTerminalView.
    // Sends tmux sequences (\x02 + key) directly to the local PTY.

    private func installKeyMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Accept if the terminal or any of its descendant views is first responder
            guard let fr = self.view.window?.firstResponder as? NSView,
                  (fr === self.terminal || fr.isDescendant(of: self.terminal)) else { return event }
            if self.handleTmuxShortcut(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    /// Returns true if event was consumed as a tmux shortcut.
    private func handleTmuxShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let cmdShift = flags.contains(.command) && flags.contains(.shift) &&
                       !flags.contains(.option) && !flags.contains(.control)
        guard cmdShift else { return false }

        let arrowEscapes: [UInt16: String] = [
            126: "\u{1b}[A",  // Up
            125: "\u{1b}[B",  // Down
            123: "\u{1b}[D",  // Left
            124: "\u{1b}[C",  // Right
        ]
        if let escape = arrowEscapes[event.keyCode] {
            sendLocal("\u{02}" + escape)
            return true
        }

        let tmuxShortcuts: [Character: String] = [
            "\\": "\u{02}%",
            "|":  "\u{02}%",   // Shift+\
            "-":  "\u{02}\"",
            "_":  "\u{02}\"",  // Shift+- (what charactersIgnoringModifiers gives for Cmd+Shift+-)
            "k":  "\u{02}x",
            "z":  "\u{02}z",
            "s":  "\u{02}s",
            "h":  "\u{02}[",
            "x":  "\u{02}d",
            " ":  "\u{02} ",
        ]
        let ch = event.charactersIgnoringModifiers?.lowercased().first
        if let key = ch, let seq = tmuxShortcuts[key] {
            sendLocal(seq)
            return true
        }
        return false
    }

    private func sendLocal(_ string: String) {
        let bytes = Array(string.utf8)
        terminal.send(source: terminal, data: bytes[...])
    }
    
    @objc
    func zoomGestureHandler (_ sender: NSMagnificationGestureRecognizer) {
        if sender.magnification > 0 {
            biggerFont (sender)
        } else {
            smallerFont(sender)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        changingSize = true
        terminal.frame = view.frame
        changingSize = false
        terminal.needsLayout = true
    }


    @objc @IBAction
    func set80x25 (_ source: AnyObject)
    {
        terminal.resize(cols: 80, rows: 25)
    }

    var lowerCol = 80
    var lowerRow = 25
    var higherCol = 160
    var higherRow = 60
    
    func queueNextSize ()
    {
        // If they requested a stop
        if resizificating == 0 {
            return
        }
        var next = terminal.getTerminal().getDims ()
        if resizificating > 0 {
            if next.cols < higherCol {
                next.cols += 1
            }
            if next.rows < higherRow {
                next.rows += 1
            }
        } else {
            if next.cols > lowerCol {
                next.cols -= 1
            }
            if next.rows > lowerRow {
                next.rows -= 1
            }
        }
        terminal.resize (cols: next.cols, rows: next.rows)
        var direction = resizificating
        
        if next.rows == higherRow && next.cols == higherCol {
            direction = -1
        }
        if next.rows == lowerRow && next.cols == lowerCol {
            direction = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.resizificating = direction
            self.queueNextSize()
        }
    }
    
    var resizificating = 0
    
    @objc @IBAction
    func resizificator (_ source: AnyObject)
    {
        if resizificating != 1 {
            resizificating = 1
            queueNextSize ()
        } else {
            resizificating = 0
        }
    }

    @objc @IBAction
    func resizificatorDown (_ source: AnyObject)
    {
        if resizificating != -1 {
            resizificating = -1
            queueNextSize ()
        } else {
            resizificating = 0
        }
    }

    @objc @IBAction
    func toggleMetalRenderer(_ source: AnyObject) {
        do {
            try terminal.setUseMetal(!terminal.isUsingMetalRenderer)
        } catch {
            print("METAL TOGGLE FAILED: \(error)")
        }
        terminal.setNeedsDisplay(terminal.bounds)
    }

    @objc @IBAction
    func toggleMetalBufferingMode(_ source: AnyObject) {
        let current = terminal.metalBufferingMode
        terminal.metalBufferingMode = (current == .perRowPersistent) ? .perFrameAggregated : .perRowPersistent
        terminal.setNeedsDisplay(terminal.bounds)
    }

    @objc @IBAction
    func allowMouseReporting (_ source: AnyObject)
    {
        terminal.allowMouseReporting.toggle ()
    }

    @objc @IBAction
    func toggleCustomBlockGlyphs (_ source: AnyObject)
    {
        terminal.customBlockGlyphs.toggle()
    }

    @objc @IBAction
    func toggleAnsi256PaletteStrategy (_ source: AnyObject)
    {
        let term = terminal.getTerminal()
        term.ansi256PaletteStrategy = term.ansi256PaletteStrategy == .base16Lab ? .xterm : .base16Lab
    }
    
    @objc @IBAction
    func exportBuffer (_ source: AnyObject)
    {
        saveData { self.terminal.getTerminal().getBufferAsData () }
    }

    @objc @IBAction
    func exportSelection (_ source: AnyObject)
    {
        saveData {
            if let str = self.terminal.getSelection () {
                return str.data (using: .utf8) ?? Data ()
            }
            return Data ()
        }
    }

    func saveData (_ getData: @escaping () -> Data)
    {
        let savePanel = NSSavePanel ()
        savePanel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            savePanel.allowedContentTypes = [UTType.text, UTType.plainText]
        } else {
            savePanel.allowedFileTypes = ["txt"]
        }
        savePanel.title = "Export Buffer Contents As Text"
        savePanel.nameFieldStringValue = "TerminalCapture"
        
        savePanel.begin { (result) in
            if result.rawValue == NSApplication.ModalResponse.OK.rawValue {
                let data = getData ()
                if let url = savePanel.url {
                    do {
                        try data.write(to: url)
                    } catch let error as NSError {
                        let alert = NSAlert (error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    @objc @IBAction
    func softReset (_ source: AnyObject)
    {
        terminal.getTerminal().softReset ()
        terminal.setNeedsDisplay(terminal.frame)
    }
    
    @objc @IBAction
    func hardReset (_ source: AnyObject)
    {
        terminal.getTerminal().resetToInitialState ()
        terminal.setNeedsDisplay(terminal.frame)
    }
    
    @objc @IBAction
    func toggleOptionAsMetaKey (_ source: AnyObject)
    {
        terminal.optionAsMetaKey.toggle ()
    }
    
    @objc @IBAction
    func biggerFont (_ source: AnyObject)
    {
        let size = terminal.font.pointSize
        guard size < 72 else {
            return
        }
        
        terminal.applyJetBrainsMono(size: size+1)
    }

    @objc @IBAction
    func smallerFont (_ source: AnyObject)
    {
        let size = terminal.font.pointSize
        guard size > 5 else {
            return
        }

        terminal.applyJetBrainsMono(size: size-1)
    }

    @objc @IBAction
    func defaultFontSize  (_ source: AnyObject)
    {
        terminal.applyJetBrainsMono(size: NSFont.systemFontSize)
    }

    @objc private func preferencesChanged() {
        applyAppearance()
    }

    private func applyAppearance() {
        let theme = ColorTheme.active
        let (fr, fg, fb) = ColorTheme.rgb8(from: theme.foregroundHex)
        let (br, bg, bb) = ColorTheme.rgb8(from: theme.backgroundHex)
        let (cr, cg, cb) = ColorTheme.rgb8(from: theme.defaultCursorHex)

        let fgColor = NSColor(calibratedRed: CGFloat(fr)/255, green: CGFloat(fg)/255, blue: CGFloat(fb)/255, alpha: 1)
        let bgColor = NSColor(calibratedRed: CGFloat(br)/255, green: CGFloat(bg)/255, blue: CGFloat(bb)/255, alpha: 1)
        let cursorColor = NSColor(calibratedRed: CGFloat(cr)/255, green: CGFloat(cg)/255, blue: CGFloat(cb)/255, alpha: 1)

        terminal.nativeForegroundColor = fgColor
        terminal.nativeBackgroundColor = bgColor
        terminal.layer?.backgroundColor = bgColor.cgColor
        terminal.caretColor = cursorColor
        terminal.installColors(theme.palette)
        terminal.applyJetBrainsMono(size: TerminalPreferences.shared.fontSize)
    }


    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool
    {
        if item.action == #selector(debugToggleHostLogging(_:)) {
            if let m = item as? NSMenuItem {
                m.state = logging ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(resizificator(_:)) {
            if let m = item as? NSMenuItem {
                m.state = resizificating == 1 ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(resizificatorDown(_:)) {
            if let m = item as? NSMenuItem {
                m.state = resizificating == -1 ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(allowMouseReporting(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.allowMouseReporting ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleCustomBlockGlyphs(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.customBlockGlyphs ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleAnsi256PaletteStrategy(_:)) {
            if let m = item as? NSMenuItem {
                let term = terminal.getTerminal()
                m.state = term.ansi256PaletteStrategy == .base16Lab ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleOptionAsMetaKey(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.optionAsMetaKey ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleMetalRenderer(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.isUsingMetalRenderer ? .on : .off
            }
        }
        if item.action == #selector(toggleMetalBufferingMode(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.metalBufferingMode == .perFrameAggregated ? .on : .off
            }
        }
        
        // Only enable "Export selection" if we have a selection
        if item.action == #selector(exportSelection(_:)) {
            return terminal.selectionActive
        }
        return true
    }
    
    @objc @IBAction
    func debugToggleHostLogging (_ source: AnyObject)
    {
        logging = !logging
        updateLogging()
    }
    
}
