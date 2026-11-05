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

/// Small transient "toast" shown in the middle-bottom of the screen with liquid glass aesthetic.
@MainActor
enum HUD {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        hideWork?.cancel()
        window?.orderOut(nil)
        Haptics.tap()

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
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        window = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.28; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

private struct HUDView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.2), radius: 16, x: 0, y: 8)
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
                    ? Color.accentColor.opacity(0.25)
                    : (isHovered ? Color.black.opacity(0.08) : Color.clear),
                radius: isSelected ? 10 : (isHovered ? 6 : 0),
                x: 0,
                y: isSelected ? 3 : 2
            )
            .scaleEffect(isHovered && !isSelected ? 1.004 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHovered)
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
        Haptics.tap()
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
