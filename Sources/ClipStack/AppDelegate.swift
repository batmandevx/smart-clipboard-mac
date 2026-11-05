import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ClipboardStore.shared
    private let queueManager = QueueManager.shared
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var historyHotKey: HotKey?
    private var textHotKey: HotKey?
    private var queueHotKey: HotKey?
    private let screenshots = ScreenshotWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        panel = PanelController(store: store)
        panel.onOpenSettings = { [weak self] _ in
            self?.showMenu()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipStack")
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        registerHotKeys()

        screenshots.onScreenshot = { [weak self] url in self?.handleScreenshot(url) }
        if Prefs.watchScreenshots { screenshots.start() }

        if Prefs.autoPaste && !Paster.isTrusted && !Prefs.didPromptAccessibility {
            Prefs.didPromptAccessibility = true
            Paster.requestAccess()
        }

        if !Prefs.didShowWelcome {
            Prefs.didShowWelcome = true
            HUD.show("ClipStack is running — press \(HotkeyPreset.current.title)", symbol: "doc.on.clipboard")
        }
    }

    // MARK: - Status item click & Menu

    func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menuNeedsUpdate(menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            panel.toggle(nearItem: statusItem)
        }
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        historyHotKey?.unregister()
        let preset = HotkeyPreset.current
        historyHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
            self?.panel.toggle(nearMouse: true)
        }
        if historyHotKey == nil {
            HUD.show("\(preset.title) is used by another app", symbol: "exclamationmark.triangle.fill")
        }

        if textHotKey == nil {
            let t = HotkeyPreset.textCapture
            textHotKey = HotKey(keyCode: t.keyCode, modifiers: t.modifiers) { ScreenTextCapture.start() }
        }

        if queueHotKey == nil {
            let q = HotkeyPreset.queuePaste
            queueHotKey = HotKey(keyCode: q.keyCode, modifiers: q.modifiers) { [weak self] in
                if self?.queueManager.isActive == true {
                    self?.queueManager.pasteNext()
                } else {
                    HUD.show("Queue mode not active", symbol: "list.number")
                }
            }
        }
    }

    // MARK: - Screenshots

    private func handleScreenshot(_ url: URL) {
        guard let item = store.addImage(fileURL: url, source: "Screenshot") else { return }
        if Prefs.copyScreenshots { store.copyToPasteboard(item) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item("Open Clipboard History", key: HotkeyPreset.current.title, action: #selector(openHistory)))
        menu.addItem(item("Extract Text from Screen…", key: HotkeyPreset.textCapture.title, action: #selector(captureText)))

        if queueManager.isActive {
            menu.addItem(item("Paste Next in Queue (\(queueManager.currentIndex + 1)/\(queueManager.queue.count))",
                              key: HotkeyPreset.queuePaste.title, action: #selector(pasteNextQueue)))
            menu.addItem(item("Stop Queue Mode", action: #selector(toggleQueueMode)))
        } else {
            menu.addItem(item("Start Sequential Queue (Recent 5)", action: #selector(toggleQueueMode)))
        }

        menu.addItem(.separator())

        // History size
        let sizeMenu = NSMenu()
        for n in [20, 50, 100, 200, 500] {
            let mi = item("\(n) items", action: #selector(setLimit(_:)))
            mi.tag = n
            mi.state = Prefs.historyLimit == n ? .on : .off
            sizeMenu.addItem(mi)
        }
        let sizeItem = NSMenuItem(title: "History Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // Hotkey
        let hkMenu = NSMenu()
        for (i, p) in HotkeyPreset.all.enumerated() {
            let mi = item(p.title, action: #selector(setHotkey(_:)))
            mi.tag = i
            mi.state = Prefs.hotkeyPreset == i ? .on : .off
            hkMenu.addItem(mi)
        }
        let hkItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        hkItem.submenu = hkMenu
        menu.addItem(hkItem)

        let auto = item(Paster.isTrusted || !Prefs.autoPaste ? "Paste Automatically"
                                                             : "Paste Automatically (needs permission)",
                        action: #selector(toggleAutoPaste))
        auto.state = Prefs.autoPaste ? .on : .off
        menu.addItem(auto)

        let watch = item("Save Screenshots to History", action: #selector(toggleScreenshots))
        watch.state = Prefs.watchScreenshots ? .on : .off
        menu.addItem(watch)

        let copyShots = item("Also Copy Screenshots to Clipboard", action: #selector(toggleCopyScreenshots))
        copyShots.state = Prefs.copyScreenshots ? .on : .off
        copyShots.isEnabled = Prefs.watchScreenshots
        menu.addItem(copyShots)

        let login = item("Launch at Login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let sound = item("Audio Feedback on Copy/Paste", action: #selector(toggleSoundFeedback))
        sound.state = Prefs.soundFeedback ? .on : .off
        menu.addItem(sound)

        let mask = item("Mask Sensitive Data (API keys, cards)", action: #selector(toggleMaskSensitive))
        mask.state = Prefs.autoMaskSensitive ? .on : .off
        menu.addItem(mask)

        menu.addItem(.separator())

        // Export submenu
        let exportMenu = NSMenu()
        exportMenu.addItem(item("Export as Markdown (.md)…", action: #selector(exportMarkdown)))
        exportMenu.addItem(item("Export as JSON (.json)…", action: #selector(exportJSON)))
        let exportItem = NSMenuItem(title: "Export History", action: nil, keyEquivalent: "")
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)

        menu.addItem(item("Clear History (keeps pinned)", action: #selector(clearHistory)))
        menu.addItem(item("Quit ClipStack", key: "q", action: #selector(quit)))
    }

    private func item(_ title: String, key: String = "", action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: key.count > 1 ? "\(title)    \(key)" : title,
                            action: action, keyEquivalent: key.count == 1 ? key : "")
        mi.target = self
        return mi
    }

    @objc private func openHistory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.panel.show(nearItem: self.statusItem)
        }
    }

    @objc private func captureText() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ScreenTextCapture.start() }
    }

    @objc private func toggleQueueMode() {
        if queueManager.isActive {
            queueManager.stopQueue()
        } else {
            let top5 = Array(store.items.prefix(5).reversed()) // FIFO
            queueManager.startQueue(with: top5)
        }
    }

    @objc private func pasteNextQueue() {
        queueManager.pasteNext()
    }

    @objc private func exportMarkdown() {
        promptExport(asMarkdown: true)
    }

    @objc private func exportJSON() {
        promptExport(asMarkdown: false)
    }

    private func promptExport(asMarkdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = asMarkdown ? "ClipStack-Export.md" : "ClipStack-Export.json"
        panel.begin { [weak self] res in
            guard res == .OK, let url = panel.url, let self else { return }
            do {
                if asMarkdown {
                    try self.store.exportAsMarkdown(to: url)
                } else {
                    try self.store.exportHistory(to: url)
                }
                HUD.show("Exported history!", symbol: "square.and.arrow.up.fill")
            } catch {
                HUD.show("Export failed", symbol: "exclamationmark.triangle")
            }
        }
    }

    @objc private func setLimit(_ sender: NSMenuItem) {
        Prefs.historyLimit = sender.tag
        store.applyLimit()
    }

    @objc private func setHotkey(_ sender: NSMenuItem) {
        Prefs.hotkeyPreset = sender.tag
        registerHotKeys()
        HUD.show("Shortcut: \(HotkeyPreset.current.title)", symbol: "keyboard")
    }

    @objc private func toggleAutoPaste() {
        Prefs.autoPaste.toggle()
        if Prefs.autoPaste && !Paster.isTrusted { Paster.requestAccess() }
    }

    @objc private func toggleScreenshots() {
        Prefs.watchScreenshots.toggle()
        Prefs.watchScreenshots ? screenshots.start() : screenshots.stop()
    }

    @objc private func toggleCopyScreenshots() {
        Prefs.copyScreenshots.toggle()
    }

    @objc private func toggleSoundFeedback() {
        Prefs.soundFeedback.toggle()
        if Prefs.soundFeedback {
            SoundEffects.playPaste()
        }
    }

    @objc private func toggleMaskSensitive() {
        Prefs.autoMaskSensitive.toggle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            HUD.show("Couldn't change login item", symbol: "exclamationmark.triangle.fill")
        }
    }

    @objc private func clearHistory() { store.clearUnpinned() }

    @objc private func quit() { NSApp.terminate(nil) }
}
