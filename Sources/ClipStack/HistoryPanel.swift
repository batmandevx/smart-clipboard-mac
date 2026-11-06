import AppKit
import SwiftUI
import Carbon.HIToolbox

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case snippets = "Snippets"
    case text = "Text"
    case images = "Images"
    case links = "Links"
    case code = "Code"
    case pinned = "Pinned"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .snippets: return "bookmark.fill"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .links: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pinned: return "pin.fill"
        }
    }
}

@MainActor
final class PanelState: ObservableObject {
    @Published var query = ""
    @Published var filter: ClipFilter = .all
    @Published var selection = 0
    @Published var scrollTarget: UUID?
    @Published var focusToken = 0
    @Published var quickLookItem: ClipItem?

    func filtered(_ items: [ClipItem]) -> [ClipItem] {
        let list = items.filter { filter.matches($0) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
    }
}

extension ClipFilter {
    @MainActor
    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .snippets: return item.isSnippetItem
        case .text: return item.kind == .text && !item.isSnippetItem
        case .images: return ClipTraits.of(item).isImage
        case .links: return ClipTraits.of(item).url != nil
        case .code: return ClipTraits.of(item).isCode
        case .pinned: return item.pinned
        }
    }
}

/// Expensive per-item content analysis (URL / colour / JSON / code / secrets),
/// computed once per clip instead of on every SwiftUI render.
struct ClipTraits {
    let url: URL?
    let color: NSColor?
    let sensitive: SmartText.SensitiveInfo?
    let isJSON: Bool
    let isCode: Bool
    let isImage: Bool

    private static let codeKeywords = ["func ", "def ", "class ", "const ", "let ", "var ", "import ", "<?",
                                       "<html", "SELECT ", "git ", "npm ", "docker ", "=> ", "();", "{\n"]
    @MainActor private static var cache: [String: ClipTraits] = [:]

    @MainActor
    static func of(_ item: ClipItem) -> ClipTraits {
        let key = "\(item.id.uuidString)|\(item.hash)"
        if let hit = cache[key] { return hit }
        let t = compute(item)
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = t
        return t
    }

    @MainActor
    private static func compute(_ item: ClipItem) -> ClipTraits {
        let isImage = item.kind == .image || (item.kind == .file && ClipboardStore.shared.ocrURL(for: item) != nil)
        guard item.kind == .text, let text = item.text else {
            return ClipTraits(url: nil, color: nil, sensitive: nil, isJSON: false, isCode: false, isImage: isImage)
        }
        let isJSON = SmartText.prettyJSON(from: text) != nil
        let url = SmartText.url(from: text)
        return ClipTraits(
            url: url,
            color: SmartText.color(from: text),
            sensitive: SmartText.detectSensitive(in: text),
            isJSON: isJSON,
            isCode: url == nil && (isJSON || codeKeywords.contains { text.contains($0) }),
            isImage: false
        )
    }
}

struct PanelActions {
    var paste: (ClipItem) -> Void
    var pastePlainText: (ClipItem) -> Void
    var copyOnly: (ClipItem) -> Void
    var togglePin: (ClipItem) -> Void
    var delete: (ClipItem) -> Void
    var extractText: (ClipItem) -> Void
    var applyTransform: (ClipItem, String) -> Void
    var openURL: (URL) -> Void
    var reveal: (ClipItem) -> Void
    var clear: () -> Void
    var captureScreenText: () -> Void
    var openSettings: (NSView?) -> Void
    var toggleQueue: () -> Void
    var toggleSnippet: (ClipItem) -> Void
    var createSnippet: (String, String) -> Void
    var mergeRecent: () -> Void
    var compressImage: (ClipItem, CGFloat, CGFloat) -> Void
    var convertImageToPNG: (ClipItem) -> Void
}

/// A panel that can take keyboard focus without activating the app, so the
/// app you were typing in stays frontmost and receives the paste.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        minSize = NSSize(width: 380, height: 460)
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class PanelController {
    let store: ClipboardStore
    let queueManager = QueueManager.shared
    let state = PanelState()
    var onOpenSettings: ((NSView?) -> Void)?
    private var panel: FloatingPanel!
    private var keyMonitor: Any?

    init(store: ClipboardStore) {
        self.store = store
        panel = FloatingPanel(size: NSSize(width: 420, height: 600))
        panel.onResignKey = { [weak self] in self?.hide() }

        let actions = PanelActions(
            paste: { [weak self] in self?.paste($0) },
            pastePlainText: { [weak self] in self?.pastePlainText($0) },
            copyOnly: { [weak self] in self?.copyOnly($0) },
            togglePin: { [weak self] in self?.togglePin($0) },
            delete: { [weak self] in self?.delete($0) },
            extractText: { [weak self] in self?.extractText($0) },
            applyTransform: { [weak self] item, newText in self?.applyTransform(item, newText: newText) },
            openURL: { [weak self] url in self?.openURL(url) },
            reveal: { [weak self] in self?.reveal($0) },
            clear: { [weak self] in self?.store.clearUnpinned() },
            captureScreenText: { ScreenTextCapture.start() },
            openSettings: { [weak self] view in self?.onOpenSettings?(view) },
            toggleQueue: { [weak self] in self?.toggleQueueMode() },
            toggleSnippet: { [weak self] in self?.toggleSnippet($0) },
            createSnippet: { [weak self] title, text in self?.createSnippet(title: title, text: text) },
            mergeRecent: { [weak self] in self?.mergeRecent() },
            compressImage: { [weak self] item, q, s in self?.compressImage(item, quality: q, scale: s) },
            convertImageToPNG: { [weak self] item in self?.convertImageToPNG(item) }
        )
        panel.contentView = NSHostingView(rootView: HistoryView(store: store, state: state, actions: actions))

        // The text extractor must never capture (or be blocked by) our own panel.
        ScreenTextCapture.willBegin = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(nearItem: NSStatusItem? = nil, nearMouse: Bool = false) {
        isVisible ? hide() : show(nearItem: nearItem, nearMouse: nearMouse)
    }

    func show(nearItem: NSStatusItem? = nil, nearMouse: Bool = false) {
        state.query = ""
        state.selection = 0
        state.quickLookItem = nil
        state.scrollTarget = store.items.first?.id
        position(nearItem: nearItem, nearMouse: nearMouse)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        state.focusToken += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        state.quickLookItem = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func position(nearItem: NSStatusItem?, nearMouse: Bool) {
        let size = panel.frame.size

        if let btn = nearItem?.button, let win = btn.window {
            let screenRect = win.convertToScreen(btn.bounds)
            let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
            guard let vf = screen?.visibleFrame else { panel.center(); return }

            var origin = NSPoint(x: screenRect.midX - size.width / 2, y: screenRect.minY - size.height - 6)
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
            panel.setFrameOrigin(origin)
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { panel.center(); return }

        var origin: NSPoint
        if nearMouse {
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
            if origin.y < vf.minY { origin.y = mouse.y + 12 }
        } else {
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08)
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Keyboard

    private var visibleItems: [ClipItem] { state.filtered(store.items) }

    private var selectedItem: ClipItem? {
        let items = visibleItems
        guard !items.isEmpty else { return nil }
        return items[min(max(state.selection, 0), items.count - 1)]
    }

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let count = visibleItems.count

        // ⌘1 … ⌘9 → paste that item
        if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            let items = visibleItems
            if items.indices.contains(n - 1) { paste(items[n - 1]) }
            return true
        }

        switch Int(e.keyCode) {
        case kVK_Escape:
            if state.quickLookItem != nil {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    state.quickLookItem = nil
                }
                return true
            }
            if state.query.isEmpty { hide() } else { state.query = "" }
            return true
        case kVK_Tab:
            cycleFilter(by: shift ? -1 : 1); return true
        case kVK_DownArrow:
            move(by: 1, count: count); return true
        case kVK_UpArrow:
            move(by: -1, count: count); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = selectedItem {
                if shift {
                    pastePlainText(item)
                } else {
                    paste(item)
                }
            }
            return true
        case kVK_Delete where cmd, kVK_ForwardDelete where cmd:
            if let item = selectedItem { delete(item) }
            return true
        case kVK_ANSI_P where cmd:
            if let item = selectedItem { togglePin(item) }
            return true
        case kVK_ANSI_E where cmd:
            if let item = selectedItem { extractText(item) }
            return true
        case kVK_ANSI_O where cmd:
            if let item = selectedItem, let text = item.text, let url = SmartText.url(from: text) {
                openURL(url)
                return true
            }
            return false
        case kVK_ANSI_C where cmd && state.query.isEmpty:
            if let item = selectedItem { copyOnly(item) }
            return true
        case kVK_Space where state.query.isEmpty:
            if let item = selectedItem {
                Haptics.tap()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    if state.quickLookItem?.id == item.id {
                        state.quickLookItem = nil
                    } else {
                        state.quickLookItem = item
                    }
                }
                return true
            }
            return false
        default:
            return false
        }
    }

    private func cycleFilter(by delta: Int) {
        let all = ClipFilter.allCases
        guard let i = all.firstIndex(of: state.filter) else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            state.filter = all[(i + delta + all.count) % all.count]
            state.selection = 0
        }
        state.scrollTarget = visibleItems.first?.id
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        Haptics.tap()
        state.selection = min(max(state.selection + delta, 0), count - 1)
        state.scrollTarget = visibleItems[state.selection].id
        if state.quickLookItem != nil {
            state.quickLookItem = selectedItem
        }
    }

    // MARK: - Actions

    private func paste(_ item: ClipItem) {
        Haptics.click()
        store.copyToPasteboard(item)
        hide()
        guard Prefs.autoPaste else { HUD.show("Copied"); return }
        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Paster.pasteCommandV() }
        } else {
            HUD.show("Copied — press ⌘V to paste")
        }
    }

    private func pastePlainText(_ item: ClipItem) {
        Haptics.click()
        guard let text = item.text else { paste(item); return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clean, forType: .string)
        hide()
        guard Prefs.autoPaste else { HUD.show("Copied Plain Text", symbol: "doc.plaintext"); return }
        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Paster.pasteCommandV() }
        } else {
            HUD.show("Copied Plain Text — ⌘V to paste", symbol: "doc.plaintext")
        }
    }

    private func copyOnly(_ item: ClipItem) {
        Haptics.tap()
        store.copyToPasteboard(item)
        hide()
        HUD.show("Copied")
    }

    private func togglePin(_ item: ClipItem) {
        Haptics.tap()
        store.togglePin(item)
    }

    private func delete(_ item: ClipItem) {
        Haptics.tap()
        if state.quickLookItem?.id == item.id { state.quickLookItem = nil }
        store.delete(item)
    }

    private func extractText(_ item: ClipItem) {
        guard store.ocrURL(for: item) != nil else {
            HUD.show("Not an image", symbol: "exclamationmark.triangle.fill")
            return
        }
        Haptics.tap()
        Task { @MainActor in
            let text = await store.recognizedText(for: item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                HUD.show("No text found in image", symbol: "text.magnifyingglass")
                return
            }
            let newItem = store.addText(text, source: "Text from image")
            store.copyToPasteboard(newItem)
            state.query = ""
            state.selection = 0
            state.scrollTarget = newItem.id
            HUD.show("Copied \(text.count) characters", symbol: "text.viewfinder")
        }
    }

    private func applyTransform(_ item: ClipItem, newText: String) {
        Haptics.click()
        let newItem = store.addText(newText, source: "Transformed")
        store.copyToPasteboard(newItem)
        state.quickLookItem = nil
        hide()
        guard Prefs.autoPaste else { HUD.show("Transformed & Copied", symbol: "wand.and.stars"); return }
        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Paster.pasteCommandV() }
        } else {
            HUD.show("Transformed & Copied — ⌘V", symbol: "wand.and.stars")
        }
    }

    private func toggleQueueMode() {
        if queueManager.isActive {
            queueManager.stopQueue()
        } else {
            let list = state.filtered(store.items)
            let itemsToQueue = Array(list.prefix(5).reversed())
            queueManager.startQueue(with: itemsToQueue)
        }
    }

    private func toggleSnippet(_ item: ClipItem) {
        Haptics.tap()
        store.toggleSnippet(item)
        HUD.show(item.isSnippetItem ? "Removed from snippets" : "Saved as snippet", symbol: "bookmark.fill")
    }

    private func createSnippet(title: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Haptics.click()
        let item = store.createSnippet(title: title.isEmpty ? "Snippet" : title, text: text)
        state.query = ""
        state.selection = 0
        state.scrollTarget = item.id
        HUD.show("Snippet created!", symbol: "bookmark.fill")
    }

    private func mergeRecent() {
        let textClips = store.items.filter { $0.text != nil || $0.ocrText != nil }
        guard textClips.count >= 2 else {
            HUD.show("Need at least 2 clips to merge", symbol: "rectangle.stack")
            return
        }
        let top3 = Array(textClips.prefix(3).reversed())
        let merged = SmartText.mergeClips(top3, separator: "\n\n")
        let item = store.addText(merged, source: "Merged (\(top3.count) clips)")
        store.copyToPasteboard(item)
        state.selection = 0
        state.scrollTarget = item.id
        HUD.show("Merged \(top3.count) clips & copied!", symbol: "rectangle.stack.badge.plus")
    }

    private func compressImage(_ item: ClipItem, quality: CGFloat, scale: CGFloat) {
        guard let url = store.ocrURL(for: item) ?? store.imageURL(for: item),
              let origData = try? Data(contentsOf: url) else { return }
        guard let compressed = SmartText.compressImage(data: origData, quality: quality, scale: scale) else {
            HUD.show("Compression failed", symbol: "exclamationmark.triangle")
            return
        }
        Haptics.click()
        let oldKB = origData.count / 1024
        let newKB = compressed.count / 1024
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(compressed, forType: .png)
        if let tiff = NSImage(data: compressed)?.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        let pct = Int((1.0 - (Double(compressed.count) / Double(max(origData.count, 1)))) * 100)
        HUD.show("Compressed: \(oldKB)KB → \(newKB)KB (-\(pct)%)", symbol: "arrow.down.right.and.arrow.up.left")
    }

    private func convertImageToPNG(_ item: ClipItem) {
        guard let url = store.ocrURL(for: item) ?? store.imageURL(for: item),
              let origData = try? Data(contentsOf: url),
              let png = SmartText.convertToPNG(data: origData) else { return }
        Haptics.click()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        HUD.show("Copied as PNG", symbol: "photo.badge.checkmark")
    }

    private func openURL(_ url: URL) {
        Haptics.tap()
        NSWorkspace.shared.open(url)
        hide()
    }

    private func reveal(_ item: ClipItem) {
        let url: URL? = item.kind == .file ? item.filePaths?.first.map { URL(fileURLWithPath: $0) } : store.imageURL(for: item)
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        hide()
    }
}

// MARK: - Main Views

struct HistoryView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: PanelState
    @ObservedObject private var queueManager = QueueManager.shared
    let actions: PanelActions
    @FocusState private var searchFocused: Bool
    @Namespace private var tabNamespace

    @State private var showingNewSnippet = false
    @State private var snippetTitle = ""
    @State private var snippetText = ""

    private static let corner: CGFloat = 20

    var body: some View {
        let items = state.filtered(store.items)
        let selection = items.isEmpty ? -1 : min(state.selection, items.count - 1)

        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                if queueManager.isActive { queueBanner.transition(.move(edge: .top).combined(with: .opacity)) }
                searchField
                filterBar
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)

                if items.isEmpty {
                    emptyState
                } else {
                    list(items, selection: selection)
                }
                footer
            }

            // Quick Look drawer
            if let qItem = state.quickLookItem {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { closeQuickLook() }
                    .transition(.opacity)
                    .zIndex(9)
                QuickLookDrawer(item: qItem, store: store, actions: actions, onClose: closeQuickLook)
                    .id(qItem.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.38), location: 0.0),
                            .init(color: Color.white.opacity(0.10), location: 0.35),
                            .init(color: Color.white.opacity(0.03), location: 0.70),
                            .init(color: Color.white.opacity(0.16), location: 1.0)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: queueManager.isActive)
        .popover(isPresented: $showingNewSnippet, arrowEdge: .top) {
            newSnippetPopover
        }
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onChange(of: state.query) { _, _ in state.selection = 0 }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        } else {
            ZStack {
                VisualEffect(material: .hudWindow)
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.08), location: 0.0),
                        .init(color: Color.white.opacity(0.01), location: 0.5),
                        .init(color: Color.accentColor.opacity(0.03), location: 1.0)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
    }

    private func closeQuickLook() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) { state.quickLookItem = nil }
    }

    private func list(_ items: [ClipItem], selection: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipRow(item: item, index: index, selected: index == selection,
                                store: store, state: state, actions: actions)
                            .id(item.id)
                            .onTapGesture { actions.paste(item) }
                            .onHover { inside in
                                if inside && state.selection != index { state.selection = index }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: state.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 0) {
                Text("ClipStack")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(store.items.count == 1 ? "1 item" : "\(store.items.count) items")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .fixedSize()

            Spacer(minLength: 8)

            toolbar
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolButton("text.viewfinder", help: "Extract text from screen (\(HotkeyPreset.textCapture.title))") {
                actions.captureScreenText()
            }
            toolButton(queueManager.isActive ? "stop.circle" : "list.number",
                       tint: queueManager.isActive ? .green : nil,
                       help: queueManager.isActive ? "Stop Sequential Queue" : "Queue top 5 clips (⌥⌘V pastes next)") {
                actions.toggleQueue()
            }
            toolButton("plus", help: "New snippet") { showingNewSnippet = true }

            Menu {
                Button { actions.mergeRecent() } label: {
                    Label("Merge Top 3 Clips", systemImage: "rectangle.stack.badge.plus")
                }
                Button { actions.captureScreenText() } label: {
                    Label("Extract Text from Screen", systemImage: "text.viewfinder")
                }
                Divider()
                Button(role: .destructive) { actions.clear() } label: {
                    Label("Clear History (keeps pinned)", systemImage: "trash")
                }
                Divider()
                Button { actions.openSettings(nil) } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 3)
        .glassSurface(Capsule(), interactive: true)
    }

    private func toolButton(_ symbol: String, tint: Color? = nil, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? Color.primary.opacity(0.85))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    private var queueBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
                .shadow(color: .green.opacity(0.6), radius: 3)
            Text("Queue \(queueManager.currentIndex + 1) of \(queueManager.queue.count)")
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
            Text("· \(HotkeyPreset.queuePaste.title) pastes next")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Stop") { queueManager.stopQueue() }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(0.25), lineWidth: 0.6))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: Snippet popover

    private var newSnippetPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("New Snippet", systemImage: "bookmark.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button { showingNewSnippet = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            TextField("Title (e.g. Bio, Greeting, SQL query)", text: $snippetTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $snippetText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

            HStack {
                Spacer()
                Button("Cancel") { showingNewSnippet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save Snippet") {
                    actions.createSnippet(snippetTitle, snippetText)
                    snippetTitle = ""
                    snippetText = ""
                    showingNewSnippet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
            TextField("Search clipboard", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .lineLimit(1)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(searchFocused ? 0.075 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.12),
                              lineWidth: searchFocused ? 1 : 0.6)
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .animation(.easeOut(duration: 0.15), value: state.query.isEmpty)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: Filter chips (horizontally scrollable — never squeezes or overlaps)

    private var filterBar: some View {
        let counts = filterCounts
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ClipFilter.allCases) { filter in
                        filterChip(filter, count: counts[filter] ?? 0)
                            .id(filter)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .onChange(of: state.filter) { _, f in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(f, anchor: .center) }
            }
        }
        .frame(height: 30)
        .padding(.bottom, 8)
    }

    private func filterChip(_ filter: ClipFilter, count: Int) -> some View {
        let isSelected = state.filter == filter
        return Button {
            Haptics.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                state.filter = filter
                state.selection = 0
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(filter.rawValue)
                    .font(.system(size: 11.5, weight: .medium))
                if filter != .all && count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
            .background {
                if isSelected {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 5, x: 0, y: 2)
                        .matchedGeometryEffect(id: "liquidTab", in: tabNamespace)
                } else {
                    Capsule().fill(Color.primary.opacity(0.045))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// One pass over the items instead of seven.
    private var filterCounts: [ClipFilter: Int] {
        var c: [ClipFilter: Int] = [:]
        for item in store.items {
            for f in ClipFilter.allCases where f != .all && f.matches(item) {
                c[f, default: 0] += 1
            }
        }
        return c
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: state.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(state.query.isEmpty
                 ? (state.filter == .all ? "Nothing copied yet" : "No \(state.filter.rawValue.lowercased()) yet")
                 : "No matches for “\(state.query)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(state.query.isEmpty
                 ? "Copy text, images or screenshots — or press \(HotkeyPreset.textCapture.title) to grab text from the screen."
                 : "Try another word, or press Tab to switch filters.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    hint("↩", "Paste"); hint("⇧↩", "Plain"); hint("Space", "Preview")
                    hint("⇥", "Filter"); hint("⌘P", "Pin"); hint("⌘E", "OCR")
                }
                HStack(spacing: 10) {
                    hint("↩", "Paste"); hint("⇧↩", "Plain"); hint("Space", "Preview"); hint("⇥", "Filter")
                }
                HStack(spacing: 10) {
                    hint("↩", "Paste"); hint("Space", "Preview")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 15)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Subtle press feedback for plain buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Row View

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: PanelState
    let actions: PanelActions
    @State private var hovering = false
    @State private var isRevealed = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var traits: ClipTraits { ClipTraits.of(item) }
    private var canOCR: Bool { traits.isImage }
    private var showActions: Bool { hovering || selected }

    var body: some View {
        let t = traits
        HStack(alignment: .top, spacing: 10) {
            badge(t)
            VStack(alignment: .leading, spacing: 6) {
                content(t)
                meta(t)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(isSelected: selected, isHovered: hovering, cornerRadius: 12)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu { contextMenu(t) }
    }

    // Leading type badge — gives every row a stable left edge.
    private func badge(_ t: ClipTraits) -> some View {
        let (symbol, color) = badgeStyle(t)
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(t.color.map { Color(nsColor: $0) } ?? color.opacity(0.16))
            if t.color == nil {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
        .frame(width: 26, height: 26)
    }

    private func badgeStyle(_ t: ClipTraits) -> (String, Color) {
        if t.sensitive != nil { return ("lock.fill", .orange) }
        if item.isSnippetItem { return ("bookmark.fill", .purple) }
        switch item.kind {
        case .text:
            if t.url != nil { return ("link", .blue) }
            if t.isJSON { return ("curlybraces", .orange) }
            if t.isCode { return ("chevron.left.forwardslash.chevron.right", .pink) }
            return ("text.alignleft", .secondary)
        case .image:
            return (item.source == "Screenshot" ? "camera.viewfinder" : "photo", .teal)
        case .file:
            return (canOCR ? "photo" : "doc", .indigo)
        }
    }

    @ViewBuilder
    private func content(_ t: ClipTraits) -> some View {
        switch item.kind {
        case .text:
            let isMasked = t.sensitive != nil && Prefs.autoMaskSensitive && !isRevealed
            VStack(alignment: .leading, spacing: 3) {
                if item.isSnippetItem {
                    Text(item.snippetTitle ?? "Snippet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
                if let url = t.url, let host = url.host {
                    Text(host)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                if let col = t.color {
                    Text(SmartText.hexString(from: col))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                Text(isMasked ? (t.sensitive?.masked ?? item.preview) : item.preview)
                    .font(.system(size: 12.5, design: (isMasked || t.isCode) ? .monospaced : .default))
                    .foregroundStyle(t.url != nil ? .secondary : .primary)
                    .lineLimit(t.url != nil ? 1 : 3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .image:
            thumbnail
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                if canOCR { thumbnail }
                Text(item.preview)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = store.thumbnail(for: item) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 120, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        } else {
            Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary)
        }
    }

    /// Meta line. Hover actions live here (trailing) so they never cover the clip text.
    private func meta(_ t: ClipTraits) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                if item.pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.orange)
                }
                Text(Self.relative.localizedString(for: item.date, relativeTo: Date()))
                if let source = item.source, !item.isSnippetItem {
                    Text("·")
                    Text(source)
                }
                if let w = item.pixelWidth, let h = item.pixelHeight {
                    Text("·")
                    Text("\(w)×\(h)").monospacedDigit()
                }
                if let s = t.sensitive { tag(s.type, color: .orange) }
                if t.isJSON { tag("JSON", color: .orange) }
                if canOCR && item.hasDetectedText { tag("Text", color: .accentColor) }
                if item.hasQRPayload { tag("QR", color: .blue) }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(0)

            Spacer(minLength: 6)

            ZStack(alignment: .trailing) {
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10.5, weight: .medium))
                        .opacity(showActions ? 0 : 1)
                }
                rowActions(t)
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: showActions)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .fixedSize()
    }

    private func rowActions(_ t: ClipTraits) -> some View {
        HStack(spacing: 0) {
            if t.sensitive != nil && Prefs.autoMaskSensitive {
                iconButton(isRevealed ? "eye.slash" : "eye", help: isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
            }
            iconButton("text.magnifyingglass", help: "Quick Look (Space)") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { state.quickLookItem = item }
            }
            if canOCR {
                iconButton("text.viewfinder", help: "Extract text (⌘E)") { actions.extractText(item) }
            }
            iconButton(item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin (⌘P)" : "Pin (⌘P)") { actions.togglePin(item) }
            iconButton("trash", help: "Delete (⌘⌫)", role: .destructive) { actions.delete(item) }
        }
        .padding(.horizontal, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private func iconButton(_ symbol: String, help: String, role: ButtonRole? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(role == .destructive ? Color.red.opacity(0.85) : Color.primary.opacity(0.8))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    @ViewBuilder
    private func contextMenu(_ t: ClipTraits) -> some View {
        Button("Paste") { actions.paste(item) }
        Button("Paste as Plain Text") { actions.pastePlainText(item) }
        Button("Copy Only") { actions.copyOnly(item) }
        if let url = t.url {
            Button("Open Link") { actions.openURL(url) }
        }
        if canOCR {
            Button("Extract Text") { actions.extractText(item) }
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { actions.togglePin(item) }
        Button(item.isSnippetItem ? "Remove from Snippets" : "Save as Snippet") { actions.toggleSnippet(item) }
        Button("Merge Top 3 into One") { actions.mergeRecent() }
        if item.kind != .text { Button("Show in Finder") { actions.reveal(item) } }
        Button("Quick Look") {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { state.quickLookItem = item }
        }
        Divider()
        Button("Delete", role: .destructive) { actions.delete(item) }
    }
}

// MARK: - Quick Look Glass Drawer

struct QuickLookDrawer: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let actions: PanelActions
    let onClose: () -> Void

    @State private var showingQRCode = false
    @State private var qrCodeImage: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(item.isSnippetItem ? (item.snippetTitle ?? "Snippet") : "Quick Look")
                    .font(.system(size: 13, weight: .semibold))

                if let text = item.text {
                    let stats = SmartText.stats(for: text)
                    Text("\(stats.words) words · \(stats.chars) chars")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                Spacer()

                if item.text != nil {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            if qrCodeImage == nil, let text = item.text {
                                qrCodeImage = SmartText.generateQRCode(from: text)
                            }
                            showingQRCode.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "qrcode")
                            Text(showingQRCode ? "Hide QR" : "QR Code")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(showingQRCode ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.1)

            // Content preview area
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Generated QR Code View
                    if showingQRCode, let qr = qrCodeImage {
                        VStack(spacing: 8) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 140, height: 140)
                                .padding(10)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
                            Text("Point iPhone / Android camera to scan")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }

                    if let text = item.text {
                        // URL open button if applicable
                        if let url = SmartText.url(from: text) {
                            Button {
                                actions.openURL(url)
                            } label: {
                                HStack {
                                    Image(systemName: "safari")
                                    Text("Open \(url.host ?? "Link") in Browser")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }

                        // Color swatch preview
                        if let col = SmartText.color(from: text) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: col))
                                    .frame(width: 44, height: 44)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                                    .shadow(color: Color(nsColor: col).opacity(0.4), radius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SmartText.hexString(from: col))
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    Text("Hex Color")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                        }

                        // Sensitive data banner
                        if let sensitive = SmartText.detectSensitive(in: text) {
                            HStack {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundStyle(.orange)
                                Text("Contains \(sensitive.type)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.orange)
                                Spacer()
                                Text("Masked in quick preview")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                        }

                        // Full readable text
                        Text(text)
                            .font(.system(size: 12, design: (item.text?.hasPrefix("{") == true) ? .monospaced : .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                    } else if store.ocrURL(for: item) != nil {
                        // High-res Image preview
                        if let img = store.thumbnail(for: item) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        // Scanned QR Payload inside image
                        if let qr = item.qrPayload, !qr.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "qrcode.viewfinder")
                                        .foregroundStyle(Color.accentColor)
                                    Text("Detected QR / Barcode")
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Spacer()
                                    Button("Copy Payload") {
                                        actions.copyOnly(ClipItem(kind: .text, text: qr, hash: ""))
                                    }
                                    .font(.system(size: 10.5))
                                    .buttonStyle(.borderless)
                                    if let url = URL(string: qr), url.scheme != nil {
                                        Button("Open Link") {
                                            actions.openURL(url)
                                        }
                                        .font(.system(size: 10.5))
                                        .buttonStyle(.borderless)
                                    }
                                }
                                Text(qr)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                            }
                        }

                        if let ocr = item.ocrText, !ocr.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Detected Text in Image")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Copy OCR") {
                                        actions.copyOnly(ClipItem(kind: .text, text: ocr, hash: ""))
                                    }
                                    .font(.system(size: 10.5))
                                    .buttonStyle(.borderless)
                                }
                                Text(ocr)
                                    .font(.system(size: 11.5))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider().opacity(0.1)

            // Transformations bottom bar
            if let text = item.text {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        transformPill(item.isSnippetItem ? "Unmark Snippet" : "Save as Snippet") {
                            actions.toggleSnippet(item)
                        }
                        transformPill("Plain Text") { actions.pastePlainText(item) }
                        transformPill("UPPERCASE") { actions.applyTransform(item, text.uppercased()) }
                        transformPill("lowercase") { actions.applyTransform(item, text.lowercased()) }
                        transformPill("Title Case") { actions.applyTransform(item, text.capitalized) }
                        transformPill("camelCase") { actions.applyTransform(item, SmartText.toCamelCase(text)) }
                        transformPill("snake_case") { actions.applyTransform(item, SmartText.toSnakeCase(text)) }
                        transformPill("kebab-case") { actions.applyTransform(item, SmartText.toKebabCase(text)) }
                        if let pretty = SmartText.prettyJSON(from: text) {
                            transformPill("Beautify JSON") { actions.applyTransform(item, pretty) }
                        }
                        if let min = SmartText.minifyJSON(from: text) {
                            transformPill("Minify JSON") { actions.applyTransform(item, min) }
                        }
                        if SmartText.isBase64(text), let decoded = SmartText.fromBase64(text) {
                            transformPill("Base64 Decode") { actions.applyTransform(item, decoded) }
                        } else {
                            transformPill("Base64 Encode") { actions.applyTransform(item, SmartText.toBase64(text)) }
                        }
                        transformPill("URL Encode") { actions.applyTransform(item, SmartText.urlEncode(text)) }
                        transformPill("URL Decode") { actions.applyTransform(item, SmartText.urlDecode(text)) }
                        transformPill("Strip Markdown") { actions.applyTransform(item, SmartText.stripMarkdown(text)) }
                        transformPill("Strip HTML") { actions.applyTransform(item, SmartText.stripHTML(text)) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.primary.opacity(0.02))
            } else if store.ocrURL(for: item) != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Optimize:")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        transformPill("Compress 75%") { actions.compressImage(item, 0.75, 1.0) }
                        transformPill("Resize 50%") { actions.compressImage(item, 0.8, 0.5) }
                        transformPill("Copy as PNG") { actions.convertImageToPNG(item) }
                        if let ocr = item.ocrText, !ocr.isEmpty {
                            transformPill("Copy Text (OCR)") {
                                actions.copyOnly(ClipItem(kind: .text, text: ocr, hash: ""))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.primary.opacity(0.02))
            }

            // Action row
            HStack(spacing: 10) {
                Button {
                    actions.copyOnly(item)
                    onClose()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Button {
                    actions.paste(item)
                    onClose()
                } label: {
                    Label("Paste", systemImage: "arrow.right.doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))
        }
        .frame(maxWidth: .infinity, maxHeight: 400)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: .popover)
        .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 10)
        .padding(8)
    }

    private func transformPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
