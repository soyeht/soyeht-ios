//
//  LocalShellWindowController.swift
//  MacTerminal
//

import Cocoa

class LocalShellWindowController: NSWindowController, NSToolbarDelegate {

    private var instancePickerPopover: NSPopover?
    // NSMenuToolbarItem holds a reference to the item so we can anchor the popover
    private weak var newTabToolbarItem: NSMenuToolbarItem?

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.tabbingIdentifier = "SoyehtTerminal"
        window?.tabbingMode = .preferred
        setupToolbar()
    }

    override func newWindowForTab(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let myWindow = window else { return }
        let wc = appDelegate.makeLocalShellWC()
        guard let newWindow = wc.window else { return }
        myWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(sender)
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        // Force the toolbar visible in expanded (below-titlebar) mode on all macOS versions
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .expanded
        }
        toolbar.isVisible = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("NewTabButton")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("NewTabButton")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .init("NewTabButton") else { return nil }

        let menu = NSMenu()
        let localItem = NSMenuItem(title: "New Local Shell", action: #selector(newLocalShellTab), keyEquivalent: "")
        localItem.target = self
        menu.addItem(localItem)
        let macShellItem = NSMenuItem(title: "Mac Shell (tmux)", action: #selector(showInstancePicker(_:)), keyEquivalent: "")
        macShellItem.target = self
        menu.addItem(macShellItem)
        menu.addItem(.separator())
        let soyehtItem = NSMenuItem(title: "New Soyeht Tab…", action: #selector(showInstancePicker(_:)), keyEquivalent: "")
        soyehtItem.target = self
        menu.addItem(soyehtItem)

        let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        item.label = "New Tab"
        item.toolTip = "Open a new tab"
        item.menu = menu
        item.showsIndicator = false
        newTabToolbarItem = item
        return item
    }

    // MARK: - Actions

    @objc private func newLocalShellTab() {
        (NSApp.delegate as? AppDelegate)?.openNewLocalShellWindow()
    }

    @objc func showInstancePicker(_ sender: Any?) {
        if instancePickerPopover == nil {
            let popover = NSPopover()
            popover.contentViewController = InstancePickerViewController()
            popover.behavior = .transient
            instancePickerPopover = popover
        }

        let pickerVC = instancePickerPopover!.contentViewController as! InstancePickerViewController
        pickerVC.onDismiss = { [weak self] in
            self?.instancePickerPopover?.close()
        }

        // Try the toolbar item's view first; NSMenuToolbarItem manages its button view internally
        // so item.view may be nil — in that case anchor to the top-right of the content view.
        let anchor: (rect: NSRect, view: NSView)?
        if let itemView = newTabToolbarItem?.view {
            anchor = (itemView.bounds, itemView)
        } else if let toolbar = window?.toolbar,
                  let toolbarView = toolbar.value(forKey: "_toolbarView") as? NSView,
                  let itemView = toolbarView.subviews.last {
            anchor = (itemView.bounds, itemView)
        } else if let contentView = window?.contentView {
            // Flipped contentView: maxY is the top edge in screen coords
            let rect = NSRect(x: contentView.bounds.maxX - 50, y: contentView.bounds.maxY - 1, width: 44, height: 1)
            anchor = (rect, contentView)
        } else {
            anchor = nil
        }
        if let a = anchor {
            instancePickerPopover?.show(relativeTo: a.rect, of: a.view, preferredEdge: .minY)
            // Give the popover's window key status so keyEquivalent buttons work
            DispatchQueue.main.async { [weak self] in
                self?.instancePickerPopover?.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
