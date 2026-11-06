import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon.HIToolbox

// MARK: - Model

struct SwitcherWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let icon: NSImage?

    static func == (a: SwitcherWindow, b: SwitcherWindow) -> Bool { a.id == b.id }

    var displayTitle: String { title.isEmpty ? appName : title }
}

@MainActor
final class SwitcherState: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selection = 0
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
}

// MARK: - Accessibility bridge

/// Private but long-stable AX call that maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private enum AXWindows {
    static func element(for window: SwitcherWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        // Exact match by window id, then fall back to title.
        for el in list {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(el, &wid) == .success, wid == window.id { return el }
        }
        for el in list {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
            if let t = t as? String, !t.isEmpty, t == window.title { return el }
        }
        return nil
    }

    static func focus(_ window: SwitcherWindow) {
        let app = AXUIElementCreateApplication(window.pid)
        if let el = element(for: window) {
            AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    static func close(_ window: SwitcherWindow) {
        guard let el = element(for: window) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    static func minimize(_ window: SwitcherWindow) {
        guard let el = element(for: window) else { return }
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
}

// MARK: - Controller

/// Built-in ⌥Tab window switcher: hold ⌥, tap Tab to cycle (⇧ to go back), release ⌥ to switch.
@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    private let state = SwitcherState()
    private var panel: NSPanel?
    private var nextKey: HotKey?
    private var prevKey: HotKey?
    private var modifierTimer: Timer?
    private var keyMonitor: Any?
    private var showWork: DispatchWorkItem?
    private var isOpen = false
    private var thumbTask: Task<Void, Never>?
    private var mouseAtOpen: NSPoint = .zero

    private init() {}

    // MARK: Hotkeys

    func setEnabled(_ enabled: Bool) {
        nextKey?.unregister(); prevKey?.unregister()
        nextKey = nil; prevKey = nil
        guard enabled else { return }
        nextKey = HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)) { [weak self] in self?.advance(by: 1) }
        prevKey = HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.advance(by: -1) }
        if nextKey == nil {
            HUD.show("⌥Tab is taken by another app", symbol: "exclamationmark.triangle.fill",
                     detail: "Quit AltTab (or similar) to use ClipStack's switcher")
        }
    }

    // MARK: Open / cycle / commit

    private func advance(by delta: Int) {
        if !isOpen {
            open(initialDelta: delta)
            return
        }
        move(by: delta)
    }

    private func open(initialDelta: Int) {
        let windows = Self.listWindows()
        guard !windows.isEmpty else {
            HUD.show("No windows to switch to", symbol: "macwindow.on.rectangle")
            return
        }
        if !Paster.isTrusted {
            HUD.show("Allow Accessibility for ClipStack", symbol: "lock.shield",
                     detail: "Needed to bring a specific window to the front")
            Paster.requestAccess()
        }

        isOpen = true
        state.windows = windows
        state.thumbnails = [:]
        // Index 0 is the window you're in now, so the first ⌥Tab lands on the previous one.
        let start = windows.count > 1 ? 1 : 0
        state.selection = initialDelta >= 0 ? start : windows.count - 1
        startWatchingModifiers()
        loadThumbnails(for: windows)

        // A quick ⌥Tab tap switches instantly without flashing the UI.
        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func move(by delta: Int) {
        let n = state.windows.count
        guard n > 0 else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            state.selection = (state.selection + delta + n) % n
        }
        // Cycling means the user wants to see the list.
        if panel?.isVisible != true { showWork?.cancel(); showPanel() }
    }

    private func commit() {
        guard isOpen else { return }
        let target = state.windows.indices.contains(state.selection) ? state.windows[state.selection] : nil
        close()
        if let target { AXWindows.focus(target) }
    }

    private func cancel() { close() }

    private func close() {
        isOpen = false
        showWork?.cancel(); showWork = nil
        modifierTimer?.invalidate(); modifierTimer = nil
        thumbTask?.cancel(); thumbTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
    }

    /// Releasing ⌥ commits. Polling the modifier state needs no extra permission.
    private func startWatchingModifiers() {
        modifierTimer?.invalidate()
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                if !NSEvent.modifierFlags.contains(.option) { self.commit() }
            }
        }
    }

    // MARK: Panel

    private func showPanel() {
        guard isOpen else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }

        let actions = SwitcherActions(
            // Ignore hover until the mouse actually moves, so a resting cursor doesn't steal the selection.
            select: { [weak self] i in
                guard let self, NSEvent.mouseLocation != self.mouseAtOpen else { return }
                self.state.selection = i
            },
            activate: { [weak self] i in self?.state.selection = i; self?.commit() },
            close: { [weak self] i in self?.closeWindow(at: i) },
            minimize: { [weak self] i in self?.minimizeWindow(at: i) }
        )
        let host = NSHostingView(rootView: SwitcherView(state: state, actions: actions, maxWidth: vf.width * 0.86))
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(size.width, vf.width * 0.92)
        size.height = min(size.height, vf.height * 0.85)

        mouseAtOpen = NSEvent.mouseLocation
        let p = panel ?? makePanel()
        p.contentView = host
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        installKeyMonitor()
    }

    private func makePanel() -> NSPanel {
        let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return p
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isOpen else { return e }
            switch Int(e.keyCode) {
            case kVK_Escape: self.cancel()
            case kVK_RightArrow, kVK_DownArrow: self.move(by: 1)
            case kVK_LeftArrow, kVK_UpArrow: self.move(by: -1)
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: self.commit()
            case kVK_ANSI_W: self.closeWindow(at: self.state.selection)
            case kVK_ANSI_M: self.minimizeWindow(at: self.state.selection)
            case kVK_ANSI_Q: self.quitApp(at: self.state.selection)
            default: return e
            }
            return nil
        }
    }

    private func closeWindow(at i: Int) {
        guard state.windows.indices.contains(i) else { return }
        AXWindows.close(state.windows[i])
        remove(at: i)
    }

    private func minimizeWindow(at i: Int) {
        guard state.windows.indices.contains(i) else { return }
        AXWindows.minimize(state.windows[i])
        remove(at: i)
    }

    private func quitApp(at i: Int) {
        guard state.windows.indices.contains(i) else { return }
        let pid = state.windows[i].pid
        NSRunningApplication(processIdentifier: pid)?.terminate()
        withAnimation { state.windows.removeAll { $0.pid == pid } }
        afterRemoval()
    }

    private func remove(at i: Int) {
        Haptics.tap()
        _ = withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { state.windows.remove(at: i) }
        afterRemoval()
    }

    private func afterRemoval() {
        if state.windows.isEmpty { close(); return }
        state.selection = min(state.selection, state.windows.count - 1)
    }

    // MARK: Window discovery

    /// Normal app windows on the current Space, front-to-back.
    static func listWindows() -> [SwitcherWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { apps[app.processIdentifier] = app }

        var result: [SwitcherWindow] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let app = apps[pid], app.activationPolicy == .regular,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 60, bounds.height >= 40,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
            else { continue }
            let appName = app.localizedName ?? (w[kCGWindowOwnerName as String] as? String) ?? "App"
            let title = (w[kCGWindowName as String] as? String) ?? ""
            result.append(SwitcherWindow(id: id, pid: pid, appName: appName, title: title,
                                         frame: bounds, icon: app.icon))
        }
        return result
    }

    // MARK: Thumbnails (ScreenCaptureKit, needs Screen Recording — falls back to app icons)

    private func loadThumbnails(for windows: [SwitcherWindow]) {
        thumbTask?.cancel()
        guard CGPreflightScreenCaptureAccess() else { return }
        let ids = Set(windows.map(\.id))
        thumbTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for w in targets {
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: w)
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, 520 / max(w.frame.width, 1))
                        cfg.width = max(Int(w.frame.width * scale * 2), 2)
                        cfg.height = max(Int(w.frame.height * scale * 2), 2)
                        cfg.showsCursor = false
                        let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                        return (w.windowID, img)
                    }
                }
                for await (id, img) in group {
                    guard let img, !Task.isCancelled else { continue }
                    await MainActor.run {
                        guard let self, self.isOpen else { return }
                        self.state.thumbnails[id] = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                    }
                }
            }
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Views

struct SwitcherActions {
    var select: (Int) -> Void
    var activate: (Int) -> Void
    var close: (Int) -> Void
    var minimize: (Int) -> Void
}

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    let actions: SwitcherActions
    let maxWidth: CGFloat

    private let cardWidth: CGFloat = 220
    private let spacing: CGFloat = 12

    var body: some View {
        let perRow = max(1, min(state.windows.count, Int((maxWidth - 32 + spacing) / (cardWidth + spacing))))
        let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: perRow)

        VStack(spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(Array(state.windows.enumerated()), id: \.element.id) { i, w in
                        SwitcherCard(window: w, thumbnail: state.thumbnails[w.id],
                                     selected: i == state.selection, width: cardWidth,
                                     onClose: { actions.close(i) }, onMinimize: { actions.minimize(i) })
                            .onTapGesture { actions.activate(i) }
                            .onHover { if $0 { actions.select(i) } }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 620)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                legend("⇥", "Next"); legend("⇧⇥", "Back"); legend("W", "Close")
                legend("M", "Minimize"); legend("Q", "Quit app"); legend("esc", "Cancel")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), fallback: .hudWindow)
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .padding(30)
    }

    private func legend(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 15)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
        .fixedSize()
    }
}

struct SwitcherCard: View {
    let window: SwitcherWindow
    let thumbnail: NSImage?
    let selected: Bool
    let width: CGFloat
    let onClose: () -> Void
    let onMinimize: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .padding(6)
                        .transition(.opacity)
                } else if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .opacity(0.9)
                }
            }
            .frame(height: 130)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        miniButton("minus", action: onMinimize)
                        miniButton("xmark", action: onClose)
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }

            HStack(spacing: 7) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !window.title.isEmpty {
                        Text(window.appName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func miniButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
