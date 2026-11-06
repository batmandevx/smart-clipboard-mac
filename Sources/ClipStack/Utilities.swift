import AppKit
import SwiftUI
import Carbon.HIToolbox

enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    static func click() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

enum SoundEffects {
    static func playCopy() {
        guard Prefs.soundFeedback else { return }
        NSSound(named: "Tink")?.play()
    }

    static func playPaste() {
        guard Prefs.soundFeedback else { return }
        NSSound(named: "Pop")?.play()
    }
}

/// Small transient "toast" shown near the bottom of the screen with a Liquid Glass look.
@MainActor
enum HUD {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", detail: String? = nil) {
        hideWork?.cancel()
        window?.orderOut(nil)
        Haptics.tap()

        let host = NSHostingView(rootView: HUDView(message: message, symbol: symbol, detail: detail))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the SwiftUI view draws its own soft shadow
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        window = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.28; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 1.8 : 2.6), execute: work)
    }

    /// Removes any visible toast immediately (e.g. before a screen capture).
    static func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        window?.orderOut(nil)
        window = nil
    }
}

private struct HUDView: View {
    let message: String
    let symbol: String
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, detail == nil ? 11 : 9)
        .glassSurface(Capsule(), fallback: .hudWindow)
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
        .padding(24) // room for the shadow inside the borderless window
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

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// Apple Liquid Glass surface. Uses the real `glassEffect` on macOS 26+ and a
/// vibrancy + specular-edge fallback on older systems.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive = false
    var fallback: NSVisualEffectView.Material = .popover

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(
                    ZStack {
                        VisualEffect(material: fallback)
                        if let tint { tint.opacity(0.22) }
                        LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .clipShape(shape)
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8
                    )
                )
        }
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                          fallback: NSVisualEffectView.Material = .popover) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }
}

/// Liquid Glass card modifier for rows and widgets
struct LiquidGlassModifier: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                        ? Color.accentColor.opacity(0.18)
                        : (isHovered ? Color.primary.opacity(0.075) : Color.primary.opacity(0.038))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                        ? LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.40)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.30 : 0.14),
                                Color.white.opacity(isHovered ? 0.08 : 0.02)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: isSelected ? 1.2 : 0.8
                    )
            )
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                radius: isSelected ? 8 : 0,
                x: 0,
                y: isSelected ? 3 : 2
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.80), value: isSelected)
    }
}

extension View {
    func liquidGlassCard(isSelected: Bool = false, isHovered: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        modifier(LiquidGlassModifier(isSelected: isSelected, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

/// Simulates ⌘V in the frontmost app.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func pasteCommandV() {
        SoundEffects.playPaste()
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

/// "Text Extractor": drag a region on screen (or press Space to pick a window),
/// the text inside is recognised on-device and copied.
@MainActor
enum ScreenTextCapture {
    private static var running = false

    /// Called right before the capture UI appears, so ClipStack can get its own
    /// windows (history panel, toasts…) out of the way.
    static var willBegin: (() -> Void)?

    static func start() {
        guard !running else { return }
        running = true

        willBegin?()
        HUD.dismiss()
        // Also hide any other floating ClipStack window (popovers, sheets…), but never the menu bar item.
        for w in NSApp.windows where w.isVisible && !(w.className.contains("StatusBar")) {
            w.orderOut(nil)
        }

        // Give the window server a moment to actually remove our windows from screen
        // before the capture overlay grabs the frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { launch() }
    }

    private static func launch() {
        // Without Screen Recording permission screencapture only sees the wallpaper, so OCR would find nothing.
        // But the preflight check can also say "no" when permission IS on (a grant made for an earlier build,
        // or one macOS hasn't applied yet), so it never blocks the capture: we only ask when the capture
        // actually comes back without text.
        let maybeDenied = !CGPreflightScreenCaptureAccess()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipstack-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", "-o", tmp.path] // interactive, silent, no window shadow
        p.terminationHandler = { _ in
            Task { @MainActor in
                running = false
                await finish(tmp, maybeDenied: maybeDenied)
            }
        }
        do { try p.run() } catch {
            running = false
            HUD.show("Couldn't start screen capture", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// macOS only applies a new Screen Recording grant after the app restarts, and
    /// CGPreflightScreenCaptureAccess keeps returning false until then. So: register the app
    /// (so it appears in System Settings), explain the two steps, and offer a one-click relaunch.
    private static func askForScreenRecording() {
        // Adds ClipStack to the Screen Recording list (and shows the system prompt the first time only).
        _ = CGRequestScreenCaptureAccess()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        alert.messageText = "ClipStack needs Screen Recording to read text on screen"
        alert.informativeText = """
        1. In System Settings › Privacy & Security › Screen & System Audio Recording, turn on ClipStack.
        2. Click “Relaunch ClipStack”. macOS only applies this permission after the app restarts.

        Already turned on? Just relaunch.
        """
        alert.addButton(withTitle: "Relaunch ClipStack")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func finish(_ url: URL, maybeDenied: Bool = false) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.fileExists(atPath: url.path) else { return } // cancelled with Esc
        let text = await OCR.recognize(url: url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Nothing readable and macOS says no permission: the capture most likely only saw the wallpaper.
            if maybeDenied { askForScreenRecording() } else { HUD.show("No text found", symbol: "text.magnifyingglass") }
            return
        }
        let store = ClipboardStore.shared
        let item = store.addText(text, source: "Screen text")
        store.copyToPasteboard(item)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        HUD.show("Copied \(text.count) characters", symbol: "text.viewfinder", detail: firstLine)
    }
}
