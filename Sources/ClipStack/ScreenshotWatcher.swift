import Foundation

/// Watches the screenshot folder (Desktop by default) for new screenshots
/// taken with ⌘⇧3 / ⌘⇧4 / ⌘⇧5 and reports them.
@MainActor
final class ScreenshotWatcher {
    var onScreenshot: ((URL) -> Void)?

    private var timer: Timer?
    private var seen = Set<String>()
    private var startDate = Date()

    private static let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "pdf"]

    static var folder: URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        startDate = Date()
        seen.removeAll()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        for url in files where !seen.contains(url.path) {
            guard Self.exts.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let created = values?.creationDate, created >= startDate else {
                seen.insert(url.path) // old file, ignore forever
                continue
            }
            guard (values?.fileSize ?? 0) > 0 else { continue } // still being written
            seen.insert(url.path)
            if Self.isScreenshot(url) { onScreenshot?(url) }
        }
    }

    /// macOS tags screenshots with this extended attribute regardless of language.
    private static func isScreenshot(_ url: URL) -> Bool {
        let tagged = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
        }
        if tagged { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("CleanShot")
    }
}

