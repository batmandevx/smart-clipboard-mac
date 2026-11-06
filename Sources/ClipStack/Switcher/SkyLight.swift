import AppKit

/// Thin, defensive bridge to the private window-server (SkyLight/CGS) calls macOS window
/// switchers rely on: which Space a window lives on, and focusing a window on another Space.
/// Every symbol is resolved at runtime with dlsym, so if Apple ever removes one we degrade
/// gracefully (current Space only, app-level activation) instead of crashing.
enum SkyLight {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let handles: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
    ]

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        for h in handles + [UnsafeMutableRawPointer(bitPattern: -2)] {
            if let p = dlsym(h, name) { return unsafeBitCast(p, to: T.self) }
        }
        return nil
    }

    private static let mainConnection = sym("CGSMainConnectionID", as: MainConnFn.self)
    private static let copyDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpacesFn.self)
    private static let copySpacesForWindows = sym("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let setFrontProcess = sym("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecord = sym("SLPSPostEventRecordTo", as: PostEventRecordFn.self)
    private static let getProcessForPID = sym("GetProcessForPID", as: GetProcessForPIDFn.self)
    private typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> CGError
    private static let setSymbolicHotKey = sym("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyFn.self)

    /// System shortcuts: 1 = ⌘Tab, 2 = ⌘⇧Tab, 6 = ⌘` (cycle app windows).
    static func setSystemSwitcherEnabled(_ enabled: Bool, includeGrave: Bool) {
        guard let setSymbolicHotKey else { return }
        _ = setSymbolicHotKey(1, enabled)
        _ = setSymbolicHotKey(2, enabled)
        if includeGrave || enabled { _ = setSymbolicHotKey(6, enabled) }
    }

    static var connection: Int32 { mainConnection?() ?? 0 }

    // MARK: Spaces

    struct SpaceInfo {
        let id: Int
        let index: Int          // 1-based, in Mission Control order across all displays
        let displayID: String
        let isFullscreen: Bool
        let isCurrent: Bool
    }

    /// All Spaces on all displays.
    static func spaces() -> [Int: SpaceInfo] {
        guard let copyDisplaySpaces, let raw = copyDisplaySpaces(connection)?.takeRetainedValue(),
              let displays = raw as? [[String: Any]] else { return [:] }
        var result: [Int: SpaceInfo] = [:]
        var index = 0
        for d in displays {
            let displayID = d["Display Identifier"] as? String ?? ""
            let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            for s in d["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = s["ManagedSpaceID"] as? Int else { continue }
                index += 1
                result[id] = SpaceInfo(id: id, index: index, displayID: displayID,
                                       isFullscreen: (s["type"] as? Int) == 4, isCurrent: id == current)
            }
        }
        return result
    }

    /// Space ids a window belongs to (empty for minimized / non-normal windows).
    static func spaces(forWindow id: CGWindowID) -> [Int] {
        guard let copySpacesForWindows,
              let raw = copySpacesForWindows(connection, 0x7, [id] as CFArray)?.takeRetainedValue() else { return [] }
        return raw as? [Int] ?? []
    }

    // MARK: Focus

    /// Brings a specific window to the front and makes it key, switching Spaces if needed.
    /// Returns false if the private calls aren't available.
    @discardableResult
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        // 0x200 = "user generated" activation, which also follows the window to its Space.
        guard setFrontProcess(&psn, windowID, 0x200) == .success else { return false }

        // Synthesise the two window-server events that make the window key.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
        return true
    }
}
