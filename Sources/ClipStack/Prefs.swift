import Foundation
import Carbon.HIToolbox

/// Simple UserDefaults-backed preferences.
enum Prefs {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? def
    }

    /// Number of (unpinned) items to keep.
    static var historyLimit: Int {
        get { let v = d.integer(forKey: "historyLimit"); return v == 0 ? 20 : v }
        set { d.set(newValue, forKey: "historyLimit") }
    }

    /// Simulate ⌘V after choosing an item (needs Accessibility permission).
    static var autoPaste: Bool {
        get { bool("autoPaste", default: true) }
        set { d.set(newValue, forKey: "autoPaste") }
    }

    /// Add screenshots saved to disk into the history.
    static var watchScreenshots: Bool {
        get { bool("watchScreenshots", default: true) }
        set { d.set(newValue, forKey: "watchScreenshots") }
    }

    /// Also put new screenshots on the clipboard (like Windows' Win+Shift+S).
    static var copyScreenshots: Bool {
        get { bool("copyScreenshots", default: true) }
        set { d.set(newValue, forKey: "copyScreenshots") }
    }

    static var hotkeyPreset: Int {
        get { d.integer(forKey: "hotkeyPreset") }
        set { d.set(newValue, forKey: "hotkeyPreset") }
    }

    static var didPromptAccessibility: Bool {
        get { bool("didPromptAccessibility", default: false) }
        set { d.set(newValue, forKey: "didPromptAccessibility") }
    }

    static var soundFeedback: Bool {
        get { bool("soundFeedback", default: true) }
        set { d.set(newValue, forKey: "soundFeedback") }
    }

    static var autoMaskSensitive: Bool {
        get { bool("autoMaskSensitive", default: true) }
        set { d.set(newValue, forKey: "autoMaskSensitive") }
    }

    static var didShowWelcome: Bool {
        get { bool("didShowWelcome", default: false) }
        set { d.set(newValue, forKey: "didShowWelcome") }
    }
}

struct HotkeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let all: [HotkeyPreset] = [
        HotkeyPreset(title: "⌘⇧V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)),
        HotkeyPreset(title: "⌥V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey)),
        HotkeyPreset(title: "⌃⌥V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)),
        HotkeyPreset(title: "⌘⌥V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey)),
        HotkeyPreset(title: "⌃⇧V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey)),
    ]

    static var current: HotkeyPreset {
        let i = Prefs.hotkeyPreset
        return all.indices.contains(i) ? all[i] : all[0]
    }

    /// Fixed hotkey for "extract text from a screen region".
    static let textCapture = HotkeyPreset(title: "⌘⇧2", keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey))

    /// Fixed hotkey for "Paste next in Sequential Queue".
    static let queuePaste = HotkeyPreset(title: "⌥⌘V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey))
}

