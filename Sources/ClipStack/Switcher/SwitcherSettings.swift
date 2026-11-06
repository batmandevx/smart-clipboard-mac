import AppKit
import Carbon.HIToolbox

enum HoldModifier: Int, CaseIterable, Identifiable {
    case option, control, command
    var id: Int { rawValue }
    var symbol: String { ["⌥", "⌃", "⌘"][rawValue] }
    var title: String { ["Option ⌥", "Control ⌃", "Command ⌘ (replaces ⌘Tab)"][rawValue] }
    var carbon: UInt32 { [UInt32(optionKey), UInt32(controlKey), UInt32(cmdKey)][rawValue] }
    var flag: NSEvent.ModifierFlags { [.option, .control, .command][rawValue] }
}

enum AppsScope: Int, CaseIterable, Identifiable {
    case all, activeApp
    var id: Int { rawValue }
    var title: String { ["All apps", "Active app only"][rawValue] }
}

enum SpacesScope: Int, CaseIterable, Identifiable {
    case all, current
    var id: Int { rawValue }
    var title: String { ["All Spaces", "Current Space only"][rawValue] }
}

enum ScreensScope: Int, CaseIterable, Identifiable {
    case all, current
    var id: Int { rawValue }
    var title: String { ["All screens", "Screen showing the switcher"][rawValue] }
}

enum WindowOrder: Int, CaseIterable, Identifiable {
    case recentlyUsed, appName, windowTitle, space
    var id: Int { rawValue }
    var title: String { ["Recently used", "App name (A–Z)", "Window title (A–Z)", "Space"][rawValue] }
}

enum SwitcherStyle: Int, CaseIterable, Identifiable {
    case thumbnails, appIcons, titles
    var id: Int { rawValue }
    var title: String { ["Thumbnails", "App Icons", "Titles"][rawValue] }
}

enum SwitcherSize: Int, CaseIterable, Identifiable {
    case small, medium, large
    var id: Int { rawValue }
    var title: String { ["Small", "Medium", "Large"][rawValue] }
}

enum ShowOnScreen: Int, CaseIterable, Identifiable {
    case mouse, activeWindow, main
    var id: Int { rawValue }
    var title: String { ["Screen with the mouse", "Screen with the active window", "Main screen"][rawValue] }
}

enum ExclusionMode: Int, CaseIterable, Identifiable, Codable {
    case hideWindows, ignoreShortcut, both
    var id: Int { rawValue }
    var title: String { ["Hide its windows", "Ignore shortcut while it's active", "Both"][rawValue] }
}

struct Exclusion: Codable, Identifiable, Equatable {
    var bundleID: String
    var mode: ExclusionMode
    var id: String { bundleID }
}

/// Per-shortcut behaviour. Shortcut 1 = hold + Tab, shortcut 2 = hold + `.
struct ShortcutConfig: Codable, Equatable {
    var enabled: Bool
    var apps: Int        // AppsScope
    var spaces: Int      // SpacesScope
    var screens: Int     // ScreensScope

    var appsScope: AppsScope { AppsScope(rawValue: apps) ?? .all }
    var spacesScope: SpacesScope { SpacesScope(rawValue: spaces) ?? .all }
    var screensScope: ScreensScope { ScreensScope(rawValue: screens) ?? .all }
}

/// All window-switcher preferences, persisted in UserDefaults.
@MainActor
final class SwitcherSettings: ObservableObject {
    static let shared = SwitcherSettings()
    private let d = UserDefaults.standard

    private func int(_ k: String, _ def: Int) -> Int { d.object(forKey: "sw." + k) as? Int ?? def }
    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: "sw." + k) as? Bool ?? def }
    private func save(_ k: String, _ v: Any) { d.set(v, forKey: "sw." + k); onChange?() }

    /// Called whenever something that affects hotkeys changes.
    var onChange: (() -> Void)?

    // Controls
    @Published var holdModifier: HoldModifier { didSet { save("hold", holdModifier.rawValue) } }
    @Published var shortcut1: ShortcutConfig { didSet { saveCodable("s1", shortcut1) } }
    @Published var shortcut2: ShortcutConfig { didSet { saveCodable("s2", shortcut2) } }
    @Published var quickTapSwitches: Bool { didSet { save("quickTap", quickTapSwitches) } }
    @Published var cursorFollowsFocus: Bool { didSet { save("cursorFollows", cursorFollowsFocus) } }
    @Published var mouseHoverSelects: Bool { didSet { save("hoverSelects", mouseHoverSelects) } }

    // Filters
    @Published var showMinimized: Bool { didSet { save("minimized", showMinimized) } }
    @Published var showHidden: Bool { didSet { save("hidden", showHidden) } }
    @Published var showFullscreen: Bool { didSet { save("fullscreen", showFullscreen) } }
    @Published var showWindowless: Bool { didSet { save("windowless", showWindowless) } }
    @Published var order: WindowOrder { didSet { save("order", order.rawValue) } }

    // Appearance
    @Published var style: SwitcherStyle { didSet { save("style", style.rawValue) } }
    @Published var size: SwitcherSize { didSet { save("size", size.rawValue) } }
    @Published var showOn: ShowOnScreen { didSet { save("showOn", showOn.rawValue) } }
    @Published var delayMs: Int { didSet { save("delay", delayMs) } }
    @Published var previewSelected: Bool { didSet { save("preview", previewSelected) } }
    @Published var showSpaceBadge: Bool { didSet { save("spaceBadge", showSpaceBadge) } }
    @Published var showStatusBadges: Bool { didSet { save("statusBadges", showStatusBadges) } }
    @Published var showAppName: Bool { didSet { save("appName", showAppName) } }

    // Exclusions
    @Published var exclusions: [Exclusion] { didSet { saveCodable("exclusions", exclusions) } }

    private init() {
        func codable<T: Decodable>(_ k: String, _ def: T) -> T {
            guard let data = UserDefaults.standard.data(forKey: "sw." + k),
                  let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
            return v
        }
        let d = UserDefaults.standard
        func i(_ k: String, _ def: Int) -> Int { d.object(forKey: "sw." + k) as? Int ?? def }
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: "sw." + k) as? Bool ?? def }

        holdModifier = HoldModifier(rawValue: i("hold", 0)) ?? .option
        shortcut1 = codable("s1", ShortcutConfig(enabled: true, apps: 0, spaces: 0, screens: 0))
        shortcut2 = codable("s2", ShortcutConfig(enabled: true, apps: 1, spaces: 0, screens: 0))
        quickTapSwitches = b("quickTap", true)
        cursorFollowsFocus = b("cursorFollows", false)
        mouseHoverSelects = b("hoverSelects", true)

        showMinimized = b("minimized", true)
        showHidden = b("hidden", true)
        showFullscreen = b("fullscreen", true)
        showWindowless = b("windowless", false)
        order = WindowOrder(rawValue: i("order", 0)) ?? .recentlyUsed

        style = SwitcherStyle(rawValue: i("style", 0)) ?? .thumbnails
        size = SwitcherSize(rawValue: i("size", 1)) ?? .medium
        showOn = ShowOnScreen(rawValue: i("showOn", 0)) ?? .mouse
        delayMs = i("delay", 120)
        previewSelected = b("preview", true)
        showSpaceBadge = b("spaceBadge", true)
        showStatusBadges = b("statusBadges", true)
        showAppName = b("appName", true)

        exclusions = codable("exclusions", [])
    }

    private func saveCodable<T: Encodable>(_ k: String, _ v: T) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: "sw." + k) }
        onChange?()
    }

    func exclusion(for bundleID: String?) -> ExclusionMode? {
        guard let bundleID else { return nil }
        return exclusions.first { $0.bundleID == bundleID }?.mode
    }

    func config(for shortcut: Int) -> ShortcutConfig { shortcut == 2 ? shortcut2 : shortcut1 }
}
