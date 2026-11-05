import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Small transient "toast" shown in the middle-bottom of the screen.
@MainActor
enum HUD {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        hideWork?.cancel()
        window?.orderOut(nil)

        let host = NSHostingView(rootView: HUDView(message: message, symbol: symbol))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.18))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        window = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

private struct HUDView: View {
    let message: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
            Text(message).font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(Capsule())
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Simulates ⌘V in the frontmost app.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func pasteCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// "Text Extractor": drag a region on screen, the text inside is copied.
@MainActor
enum ScreenTextCapture {
    private static var running = false

    static func start() {
        guard !running else { return }
        running = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipstack-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", tmp.path] // interactive, silent
        p.terminationHandler = { _ in
            Task { @MainActor in
                running = false
                await finish(tmp)
            }
        }
        do { try p.run() } catch { running = false }
    }

    private static func finish(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.fileExists(atPath: url.path) else { return } // cancelled with Esc
        let text = await OCR.recognize(url: url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            HUD.show("No text found", symbol: "text.magnifyingglass")
            return
        }
        let store = ClipboardStore.shared
        let item = store.addText(text, source: "Screen text")
        store.copyToPasteboard(item)
        HUD.show("Copied \(text.count) characters", symbol: "text.viewfinder")
    }
}

