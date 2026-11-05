import Carbon.HIToolbox
import Foundation

/// Global hotkey using the Carbon API (works without Accessibility permission).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.installIfNeeded()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x434C_5053) /* 'CLPS' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }

    deinit { unregister() }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

