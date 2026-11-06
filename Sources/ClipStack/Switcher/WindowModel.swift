import AppKit

struct SwitcherWindow: Identifiable, Equatable {
    /// Real CGWindowID, or 0 for a windowless app entry.
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let title: String
    let frame: CGRect            // CG (top-left origin) coordinates
    let icon: NSImage?
    let isMinimized: Bool
    let isAppHidden: Bool
    let isFullscreen: Bool
    let spaceIndex: Int?
    let isOnCurrentSpace: Bool
    let isWindowless: Bool
    let zOrder: Int

    var id: String { isWindowless ? "app-\(pid)" : "win-\(windowID)" }
    var displayTitle: String { title.isEmpty ? appName : title }

    static func == (a: SwitcherWindow, b: SwitcherWindow) -> Bool { a.id == b.id }

    /// Screen containing most of the window.
    var screen: NSScreen? {
        guard !isWindowless else { return nil }
        let cocoa = Geometry.cocoaRect(fromCG: frame)
        return NSScreen.screens.max { a, b in
            a.frame.intersection(cocoa).area < b.frame.intersection(cocoa).area
        }
    }
}

enum Geometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Accessibility helpers

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25) // never let a hung app freeze the switcher
        return el
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    struct WindowState {
        let element: AXUIElement
        let minimized: Bool
        let fullscreen: Bool
        let subrole: String?
        let title: String?
    }

    /// AX windows of an app keyed by CGWindowID (current Space + minimized windows).
    static func windows(of pid: pid_t) -> [CGWindowID: WindowState] {
        let appEl = app(pid)
        guard let list: [AXUIElement] = attr(appEl, kAXWindowsAttribute) else { return [:] }
        var out: [CGWindowID: WindowState] = [:]
        for el in list {
            guard let id = windowID(el) else { continue }
            out[id] = WindowState(
                element: el,
                minimized: attr(el, kAXMinimizedAttribute) ?? false,
                fullscreen: attr(el, "AXFullScreen") ?? false,
                subrole: attr(el, kAXSubroleAttribute),
                title: attr(el, kAXTitleAttribute)
            )
        }
        return out
    }

    static func element(for w: SwitcherWindow) -> AXUIElement? {
        guard !w.isWindowless else { return nil }
        return windows(of: w.pid)[w.windowID]?.element
    }
}

// MARK: - Discovery

@MainActor
enum WindowDiscovery {
    struct Options {
        var apps: AppsScope
        var spaces: SpacesScope
        var screens: ScreensScope
        var targetScreen: NSScreen?
        var showMinimized: Bool
        var showHidden: Bool
        var showFullscreen: Bool
        var showWindowless: Bool
        var order: WindowOrder
        var excludedBundleIDs: Set<String>
    }

    static func windows(_ o: Options) -> [SwitcherWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != myPID
            && !o.excludedBundleIDs.contains(app.bundleIdentifier ?? "") {
            if o.apps == .activeApp && app.processIdentifier != frontPID { continue }
            apps[app.processIdentifier] = app
        }

        let spaces = SkyLight.spaces()
        let haveSpaces = !spaces.isEmpty
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        var axCache: [pid_t: [CGWindowID: AX.WindowState]] = [:]
        func ax(_ pid: pid_t) -> [CGWindowID: AX.WindowState] {
            if let c = axCache[pid] { return c }
            let w = AX.windows(of: pid)
            axCache[pid] = w
            return w
        }

        var result: [SwitcherWindow] = []
        var pidsWithWindows = Set<pid_t>()

        for (z, w) in info.enumerated() {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let app = apps[pid],
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd),
                  frame.width >= 100, frame.height >= 100,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
            else { continue }

            let axState = ax(pid)[id]
            let windowSpaces = SkyLight.spaces(forWindow: id)
            let spaceInfos = windowSpaces.compactMap { spaces[$0] }
            let onCurrent = haveSpaces ? spaceInfos.contains { $0.isCurrent }
                                       : (w[kCGWindowIsOnscreen as String] as? Bool ?? false)
            let minimized = axState?.minimized ?? false
            let fullscreen = axState?.fullscreen ?? spaceInfos.contains { $0.isFullscreen }
            let title = (axState?.title?.isEmpty == false ? axState?.title : nil)
                ?? (w[kCGWindowName as String] as? String) ?? ""

            // Decide if this is a real, user-facing window.
            if let axState {
                if let sub = axState.subrole, sub != (kAXStandardWindowSubrole as String),
                   sub != (kAXDialogSubrole as String) { continue }
            } else if spaceInfos.isEmpty {
                // Not visible to AX and not on any Space: helper/off-screen junk
                // (unless the app is hidden, whose windows live nowhere until unhidden).
                if !(app.isHidden && !title.isEmpty) { continue }
            } else if onCurrent && !(w[kCGWindowIsOnscreen as String] as? Bool ?? false) {
                continue // on this Space per CGS, but AX doesn't know it and it isn't drawn: junk
            } else if title.isEmpty && frame.height < 200 {
                continue // untitled toolbar / title-strip windows of full-screen apps
            }

            // Filters
            if minimized && !o.showMinimized { continue }
            if app.isHidden && !o.showHidden { continue }
            if fullscreen && !o.showFullscreen { continue }
            if o.spaces == .current && !onCurrent && !minimized && !app.isHidden { continue }

            let entry = SwitcherWindow(
                windowID: id, pid: pid, bundleID: app.bundleIdentifier,
                appName: app.localizedName ?? (w[kCGWindowOwnerName as String] as? String) ?? "App",
                title: title, frame: frame, icon: app.icon,
                isMinimized: minimized, isAppHidden: app.isHidden, isFullscreen: fullscreen,
                spaceIndex: spaceInfos.first?.index, isOnCurrentSpace: onCurrent,
                isWindowless: false, zOrder: z
            )
            if o.screens == .current, let target = o.targetScreen, !minimized, entry.screen != target { continue }

            result.append(entry)
            pidsWithWindows.insert(pid)
        }

        if o.showWindowless {
            for (pid, app) in apps where !pidsWithWindows.contains(pid) {
                result.append(SwitcherWindow(
                    windowID: 0, pid: pid, bundleID: app.bundleIdentifier,
                    appName: app.localizedName ?? "App", title: "", frame: .zero, icon: app.icon,
                    isMinimized: false, isAppHidden: app.isHidden, isFullscreen: false,
                    spaceIndex: nil, isOnCurrentSpace: false, isWindowless: true, zOrder: Int.max
                ))
            }
        }

        return sort(result, by: o.order)
    }

    private static func sort(_ list: [SwitcherWindow], by order: WindowOrder) -> [SwitcherWindow] {
        let mru = WindowTracker.shared
        func base(_ a: SwitcherWindow, _ b: SwitcherWindow) -> Bool {
            if a.isWindowless != b.isWindowless { return !a.isWindowless }
            let ra = mru.rank(of: a), rb = mru.rank(of: b)
            if ra != rb { return ra < rb }
            return a.zOrder < b.zOrder
        }
        switch order {
        case .recentlyUsed:
            return list.sorted(by: base)
        case .appName:
            return list.sorted {
                let c = $0.appName.localizedCaseInsensitiveCompare($1.appName)
                return c == .orderedSame ? base($0, $1) : c == .orderedAscending
            }
        case .windowTitle:
            return list.sorted {
                let c = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
                return c == .orderedSame ? base($0, $1) : c == .orderedAscending
            }
        case .space:
            return list.sorted {
                let sa = $0.spaceIndex ?? Int.max, sb = $1.spaceIndex ?? Int.max
                return sa == sb ? base($0, $1) : sa < sb
            }
        }
    }
}

// MARK: - Recently-used tracking

/// Keeps a most-recently-focused list of windows by observing app activation and
/// per-app focused-window changes through Accessibility.
@MainActor
final class WindowTracker {
    static let shared = WindowTracker()

    private var order: [CGWindowID] = []
    private var appOrder: [pid_t] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        // Seed with the current on-screen stacking order (front to back).
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            order = info.compactMap { w in
                (w[kCGWindowLayer as String] as? Int) == 0 ? w[kCGWindowNumber as String] as? CGWindowID : nil
            }
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self.appActivated(app) } }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self.observe(app) } }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self.forget(app.processIdentifier) } }
        }
        refreshObservers()
    }

    /// (Re)attach AX observers, e.g. once Accessibility permission is granted.
    func refreshObservers() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
    }

    func rank(of w: SwitcherWindow) -> Int {
        if !w.isWindowless, let i = order.firstIndex(of: w.windowID) { return i }
        if let i = appOrder.firstIndex(of: w.pid) { return 100_000 + i }
        return Int.max - 1
    }

    func bump(windowID: CGWindowID, pid: pid_t) {
        if windowID != 0 {
            order.removeAll { $0 == windowID }
            order.insert(windowID, at: 0)
            if order.count > 500 { order.removeLast(order.count - 500) }
        }
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
    }

    private func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let el = AX.app(pid)
        if let win: AXUIElement = AX.attr(el, kAXFocusedWindowAttribute), let id = AX.windowID(win) {
            bump(windowID: id, pid: pid)
        } else {
            bump(windowID: 0, pid: pid)
        }
    }

    private func forget(_ pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        appOrder.removeAll { $0 == pid }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, AXIsProcessTrusted(),
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, _ in
            MainActor.assumeIsolated {
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if let id = AX.windowID(element) { WindowTracker.shared.bump(windowID: id, pid: pid) }
            }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let el = AX.app(pid)
        AXObserverAddNotification(obs, el, kAXFocusedWindowChangedNotification as CFString, nil)
        AXObserverAddNotification(obs, el, kAXMainWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }
}
