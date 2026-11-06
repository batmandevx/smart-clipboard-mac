import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon.HIToolbox

@MainActor
final class SwitcherState: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selection = 0
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var query = ""
    @Published var searching = false
    var perRow = 1
}

/// Built-in window switcher with AltTab-style behaviour:
/// hold the modifier (⌥ by default) and tap Tab (all windows) or ` (active app's windows),
/// release to focus. Keys are captured with a CGEvent tap, so the switcher never steals focus
/// and can replace ⌘Tab.
@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    let state = SwitcherState()
    private let settings = SwitcherSettings.shared

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var enabled = false
    private var systemSwitcherDisabled = false

    private(set) var isOpen = false
    private var activeShortcut = 1
    private var panel: NSPanel?
    private var host: NSHostingView<SwitcherView>?
    private var previewPanel: NSPanel?
    private var showWork: DispatchWorkItem?
    private var thumbTask: Task<Void, Never>?
    private var thumbCache: [CGWindowID: NSImage] = [:]
    private var mouseAtOpen: NSPoint = .zero
    private var targetScreen: NSScreen?
    /// Full list for the current shortcut; `state.windows` is this list filtered by the search query.
    private var allWindows: [SwitcherWindow] = []

    private init() {}

    // MARK: - Enable / disable

    func setEnabled(_ on: Bool) {
        enabled = on
        settings.onChange = { [weak self] in self?.applySystemSwitcherOverride() }
        if on {
            WindowTracker.shared.start()
            installTap()
        } else {
            removeTap()
            close()
        }
        applySystemSwitcherOverride()
    }

    /// Restore system shortcuts before quitting.
    func shutdown() {
        if systemSwitcherDisabled { SkyLight.setSystemSwitcherEnabled(true, includeGrave: true) }
        systemSwitcherDisabled = false
    }

    private func applySystemSwitcherOverride() {
        let wantOverride = enabled && tap != nil && settings.holdModifier == .command
        if wantOverride != systemSwitcherDisabled {
            SkyLight.setSystemSwitcherEnabled(!wantOverride, includeGrave: settings.shortcut2.enabled)
            systemSwitcherDisabled = wantOverride
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            Paster.requestAccess()
            HUD.show("Allow Accessibility for ClipStack", symbol: "lock.shield",
                     detail: "Needed for the window switcher. It turns on automatically once allowed")
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let s = WindowSwitcher.shared
                    guard s.enabled, AXIsProcessTrusted() else { return }
                    s.retryTimer?.invalidate(); s.retryTimer = nil
                    s.installTap()
                    WindowTracker.shared.refreshObservers()
                    s.applySystemSwitcherOverride()
                }
            }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated {
                    if let t = WindowSwitcher.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { WindowSwitcher.shared.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: callback, userInfo: nil) else {
            HUD.show("Couldn't start the window switcher", symbol: "exclamationmark.triangle.fill")
            return
        }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func removeTap() {
        retryTimer?.invalidate(); retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }

    // MARK: - Key handling (runs inside the event tap; return true to swallow)

    private func holdFlag() -> CGEventFlags {
        switch settings.holdModifier {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let flags = event.flags
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let hold = holdFlag()
        let holdDown = flags.contains(hold)
        let isTrigger = key == kVK_Tab || key == kVK_ANSI_Grave

        switch type {
        case .flagsChanged:
            // While searching you can let go of the modifier and type freely; Return selects.
            if isOpen && !holdDown && !state.searching { commit() }
            return false

        case .keyDown:
            if holdDown && isTrigger {
                let shortcut = key == kVK_Tab ? 1 : 2
                guard settings.config(for: shortcut).enabled else { return isOpen }
                if !isOpen {
                    // Only the hold modifier (plus ⇧) — leave ⌥⌘Tab etc. to other apps.
                    let others = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).subtracting(hold)
                    if !others.isEmpty { return false }
                    if let front = NSWorkspace.shared.frontmostApplication,
                       let mode = settings.exclusion(for: front.bundleIdentifier), mode != .hideWindows {
                        return false // e.g. a game or VM that needs the shortcut itself
                    }
                }
                trigger(shortcut: shortcut, backwards: flags.contains(.maskShift))
                return true
            }
            guard isOpen else { return false }
            handleKeyWhileOpen(key, shift: flags.contains(.maskShift), event: event)
            return true

        case .keyUp:
            return isOpen || (holdDown && isTrigger)

        default:
            return false
        }
    }

    private func handleKeyWhileOpen(_ key: Int, shift: Bool, event: CGEvent) {
        if state.searching {
            switch key {
            case kVK_Escape:
                state.query.isEmpty ? endSearch() : setQuery("")
            case kVK_Delete:
                if state.query.isEmpty { endSearch() } else { setQuery(String(state.query.dropLast())) }
            case kVK_Return, kVK_ANSI_KeypadEnter: commit()
            case kVK_Tab: move(by: shift ? -1 : 1)
            case kVK_RightArrow: move(by: 1)
            case kVK_LeftArrow: move(by: -1)
            case kVK_DownArrow: move(by: state.perRow)
            case kVK_UpArrow: move(by: -state.perRow)
            default:
                // Ignore modifiers so typing while still holding ⌥ gives "a", not "å".
                if let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
                   !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    setQuery(state.query + chars)
                }
            }
            return
        }
        // 1–9 jump straight to that window (works while still holding the modifier).
        let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if let n = digitKeys.firstIndex(of: key) {
            if state.windows.indices.contains(n) {
                state.selection = n
                commit()
            }
            return
        }
        switch key {
        case kVK_ANSI_Slash: beginSearch()
        case kVK_Escape: close()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: commit()
        case kVK_RightArrow: move(by: 1)
        case kVK_LeftArrow: move(by: -1)
        case kVK_DownArrow: move(by: state.perRow)
        case kVK_UpArrow: move(by: -state.perRow)
        case kVK_ANSI_W: perform(.close)
        case kVK_ANSI_M: perform(.minimize)
        case kVK_ANSI_F: perform(.fullscreen)
        case kVK_ANSI_H: perform(.hide)
        case kVK_ANSI_Q: perform(.quit)
        default: break
        }
    }

    // MARK: - Open / move / commit

    private func trigger(shortcut: Int, backwards: Bool) {
        if isOpen && shortcut == activeShortcut {
            move(by: backwards ? -1 : 1)
            return
        }
        if isOpen { close() }
        open(shortcut: shortcut, backwards: backwards)
    }

    private func resolveTargetScreen() -> NSScreen? {
        switch settings.showOn {
        case .mouse:
            return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        case .activeWindow:
            return NSScreen.main
        case .main:
            return NSScreen.screens.first
        }
    }

    private func discover(shortcut: Int) -> [SwitcherWindow] {
        let cfg = settings.config(for: shortcut)
        let hidden = Set(settings.exclusions.filter { $0.mode != .ignoreShortcut }.map(\.bundleID))
        return WindowDiscovery.windows(.init(
            apps: cfg.appsScope, spaces: cfg.spacesScope, screens: cfg.screensScope,
            targetScreen: targetScreen,
            showMinimized: settings.showMinimized, showHidden: settings.showHidden,
            showFullscreen: settings.showFullscreen, showWindowless: settings.showWindowless,
            order: settings.order, excludedBundleIDs: hidden
        ))
    }

    private func open(shortcut: Int, backwards: Bool) {
        targetScreen = resolveTargetScreen()
        let windows = discover(shortcut: shortcut)
        guard !windows.isEmpty else {
            HUD.show(shortcut == 2 ? "No other windows in this app" : "No windows to switch to",
                     symbol: "macwindow.on.rectangle")
            return
        }
        isOpen = true
        activeShortcut = shortcut
        allWindows = windows
        state.query = ""
        state.searching = false
        state.windows = windows
        state.thumbnails = thumbCache
        // In recently-used order, index 0 is the window you're in, so start on the previous one.
        let first = (settings.order == .recentlyUsed && windows.count > 1) ? 1 : 0
        state.selection = backwards ? windows.count - 1 : first
        loadThumbnails(for: windows)

        let delay = settings.quickTapSwitches ? Double(settings.delayMs) / 1000 : 0
        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = work
        if delay <= 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    private func move(by delta: Int) {
        let n = state.windows.count
        guard isOpen, n > 0 else { return }
        var next = state.selection + delta
        if abs(delta) > 1 {
            next = min(max(next, 0), n - 1)   // row jumps clamp
        } else {
            next = (next + n) % n              // Tab wraps
        }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) { state.selection = next }
        if panel?.isVisible != true { showWork?.cancel(); showPanel() }
        updatePreview()
    }

    private func select(_ i: Int) {
        guard state.windows.indices.contains(i), state.selection != i else { return }
        state.selection = i
        updatePreview()
    }

    private func commit() {
        guard isOpen else { return }
        let target = state.windows.indices.contains(state.selection) ? state.windows[state.selection] : nil
        close()
        if let target { focus(target) }
    }

    // MARK: - Search (press / while the switcher is open)

    private func beginSearch() {
        state.searching = true
        if panel?.isVisible != true { showWork?.cancel(); showPanel() } else { layoutPanel() }
    }

    private func endSearch() {
        state.searching = false
        setQuery("")
    }

    private func setQuery(_ q: String) {
        state.query = q
        let selectedID = state.windows.indices.contains(state.selection) ? state.windows[state.selection].id : nil
        let tokens = q.lowercased().split(separator: " ").map(String.init)
        state.windows = tokens.isEmpty ? allWindows : allWindows.filter { w in
            let hay = (w.title + " " + w.appName).lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        if tokens.isEmpty, let selectedID, let i = state.windows.firstIndex(where: { $0.id == selectedID }) {
            state.selection = i
        } else {
            state.selection = 0
        }
        layoutPanel()
        updatePreview()
    }

    private func close() {
        guard isOpen || panel?.isVisible == true else { return }
        isOpen = false
        showWork?.cancel(); showWork = nil
        thumbTask?.cancel(); thumbTask = nil
        panel?.orderOut(nil)
        previewPanel?.orderOut(nil)
    }

    // MARK: - Focus

    private func focus(_ w: SwitcherWindow) {
        WindowTracker.shared.bump(windowID: w.windowID, pid: w.pid)
        let app = NSRunningApplication(processIdentifier: w.pid)

        if w.isWindowless {
            if let url = app?.bundleURL {
                // "Reopen" makes most apps create a fresh window.
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                app?.activate()
            }
            return
        }

        if app?.isHidden == true { app?.unhide() }
        let el = AX.element(for: w)
        if w.isMinimized, let el {
            AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let ok = SkyLight.focus(windowID: w.windowID, pid: w.pid)
        if let el {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if !ok { app?.activate() }

        if settings.cursorFollowsFocus {
            let frame = w.frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
            }
        }
    }

    // MARK: - Window actions (W / M / F / H / Q or hover buttons)

    enum Action { case close, minimize, fullscreen, hide, quit }

    func perform(_ action: Action, at index: Int? = nil) {
        let i = index ?? state.selection
        guard state.windows.indices.contains(i) else { return }
        let w = state.windows[i]
        let app = NSRunningApplication(processIdentifier: w.pid)
        let el = AX.element(for: w)
        Haptics.tap()

        switch action {
        case .close:
            if let el, let button: AXUIElement = AX.attr(el, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            removeEntries { $0.id == w.id }
            return
        case .quit:
            app?.terminate()
            removeEntries { $0.pid == w.pid }
            return
        case .minimize:
            if let el { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, w.isMinimized ? kCFBooleanFalse : kCFBooleanTrue) }
        case .fullscreen:
            if let el { AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, w.isFullscreen ? kCFBooleanFalse : kCFBooleanTrue) }
        case .hide:
            if app?.isHidden == true { app?.unhide() } else { app?.hide() }
        }
        // State changes (minimize animation, Space change…) take a moment; then refresh the list.
        let keepID = w.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refresh(keeping: keepID) }
    }

    private func removeEntries(where predicate: (SwitcherWindow) -> Bool) {
        allWindows.removeAll(where: predicate)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { state.windows.removeAll(where: predicate) }
        if allWindows.isEmpty { close(); return }
        state.selection = min(state.selection, state.windows.count - 1)
        layoutPanel()
        updatePreview()
    }

    private func refresh(keeping id: String) {
        guard isOpen else { return }
        let windows = discover(shortcut: activeShortcut)
        guard !windows.isEmpty else { close(); return }
        allWindows = windows
        let q = state.query
        state.windows = windows
        if !q.isEmpty { setQuery(q) }
        state.selection = windows.firstIndex { $0.id == id } ?? min(state.selection, windows.count - 1)
        layoutPanel()
        updatePreview()
    }

    // MARK: - Panel

    private func showPanel() {
        guard isOpen else { return }
        mouseAtOpen = NSEvent.mouseLocation
        let p = panel ?? makePanel(level: .popUpMenu)
        panel = p
        if host == nil {
            let actions = SwitcherActions(
                hover: { [weak self] i in
                    guard let self, self.settings.mouseHoverSelects,
                          NSEvent.mouseLocation != self.mouseAtOpen else { return }
                    self.select(i)
                },
                activate: { [weak self] i in self?.state.selection = i; self?.commit() },
                perform: { [weak self] action, i in self?.perform(action, at: i) }
            )
            let h = NSHostingView(rootView: SwitcherView(state: state, settings: settings, actions: actions, maxWidth: 1000))
            host = h
            p.contentView = h
        }
        layoutPanel()
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; p.animator().alphaValue = 1 }
        updatePreview()
    }

    private func layoutPanel() {
        guard let p = panel, let host, let vf = (targetScreen ?? NSScreen.main)?.visibleFrame else { return }
        let maxWidth = vf.width * 0.9 - 60
        state.perRow = SwitcherLayout.perRow(count: state.windows.count, style: settings.style,
                                             size: settings.size, maxWidth: maxWidth)
        host.rootView = SwitcherView(state: state, settings: settings, actions: host.rootView.actions, maxWidth: maxWidth)
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(size.width, vf.width)
        size.height = min(size.height, vf.height)
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                          width: size.width, height: size.height), display: true)
    }

    private func makePanel(level: NSWindow.Level) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = level
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return p
    }

    // MARK: - Preview of the selected window at its real position

    private func updatePreview() {
        guard settings.previewSelected, isOpen, panel?.isVisible == true,
              state.windows.indices.contains(state.selection) else { previewPanel?.orderOut(nil); return }
        let w = state.windows[state.selection]
        guard !w.isWindowless, !w.isMinimized, !w.isAppHidden, w.isOnCurrentSpace,
              let img = state.thumbnails[w.windowID] else { previewPanel?.orderOut(nil); return }

        let p = previewPanel ?? makePanel(level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1))
        p.ignoresMouseEvents = true
        previewPanel = p
        p.contentView = NSHostingView(rootView: PreviewView(image: img))
        p.setFrame(Geometry.cocoaRect(fromCG: w.frame), display: true)
        p.orderFrontRegardless()
    }

    // MARK: - Thumbnails (ScreenCaptureKit; needs Screen Recording, otherwise app icons are shown)

    private func loadThumbnails(for windows: [SwitcherWindow]) {
        thumbTask?.cancel()
        guard settings.style == .thumbnails || settings.previewSelected, CGPreflightScreenCaptureAccess() else { return }
        let ids = Set(windows.filter { !$0.isWindowless }.map(\.windowID))
        thumbTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for w in targets {
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, 900 / max(w.frame.width, 1))
                        cfg.width = max(Int(w.frame.width * scale), 2)
                        cfg.height = max(Int(w.frame.height * scale), 2)
                        cfg.showsCursor = false
                        cfg.ignoreShadowsSingleWindow = true
                        let img = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
                        return (w.windowID, img)
                    }
                }
                for await (id, img) in group {
                    guard let img, !Task.isCancelled else { continue }
                    await MainActor.run {
                        guard let self else { return }
                        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                        self.thumbCache[id] = ns
                        if self.isOpen { self.state.thumbnails[id] = ns }
                        if self.isOpen, self.state.windows.indices.contains(self.state.selection),
                           self.state.windows[self.state.selection].windowID == id { self.updatePreview() }
                    }
                }
            }
            // Drop thumbnails of windows that no longer exist.
            await MainActor.run {
                guard let self else { return }
                let alive = Set(content.windows.map(\.windowID))
                self.thumbCache = self.thumbCache.filter { alive.contains($0.key) }
            }
        }
    }
}
