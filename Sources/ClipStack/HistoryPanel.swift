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
        var list = items
        switch filter {
        case .all:
            break
        case .snippets:
            list = list.filter { $0.isSnippetItem }
        case .text:
            list = list.filter { $0.kind == .text && !$0.isSnippetItem }
        case .images:
            list = list.filter { item in
                item.kind == .image || (item.kind == .file && ClipboardStore.shared.ocrURL(for: item) != nil)
            }
        case .links:
            list = list.filter { item in
                guard item.kind == .text, let text = item.text else { return false }
                return SmartText.url(from: text) != nil
            }
        case .code:
            list = list.filter { item in
                guard item.kind == .text, let text = item.text else { return false }
                if SmartText.prettyJSON(from: text) != nil { return true }
                let codeKeywords = ["func ", "def ", "class ", "const ", "let ", "var ", "import ", "<?", "<html", "SELECT ", "git ", "npm ", "docker "]
                return codeKeywords.contains { text.contains($0) }
            }
        case .pinned:
            list = list.filter { $0.pinned }
        }

        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
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
        minSize = NSSize(width: 370, height: 440)
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

    var body: some View {
        let items = state.filtered(store.items)
        let selection = items.isEmpty ? -1 : min(state.selection, items.count - 1)

        ZStack {
            // Base Apple Liquid Glass backdrop
            VisualEffect(material: .hudWindow)
                .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.08), location: 0.0),
                    .init(color: Color.white.opacity(0.01), location: 0.5),
                    .init(color: Color.accentColor.opacity(0.03), location: 1.0)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                searchField
                filterBar
                Divider().opacity(0.08)

                if items.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    ClipRow(item: item, index: index, selected: index == selection,
                                            store: store, state: state, actions: actions)
                                        .id(item.id)
                                        .onTapGesture { actions.paste(item) }
                                        .onHover { if $0 { state.selection = index } }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: state.scrollTarget) { _, target in
                            guard let target else { return }
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target) }
                        }
                    }
                }
                footer
            }

            // Quick Look Glass Drawer
            if let qItem = state.quickLookItem {
                QuickLookDrawer(item: qItem, store: store, actions: actions) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        state.quickLookItem = nil
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
                .zIndex(10)
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.40), location: 0.0),
                            .init(color: Color.white.opacity(0.12), location: 0.35),
                            .init(color: Color.white.opacity(0.03), location: 0.70),
                            .init(color: Color.white.opacity(0.20), location: 1.0)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .popover(isPresented: $showingNewSnippet, arrowEdge: .top) {
            newSnippetPopover
        }
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onChange(of: state.query) { _, _ in state.selection = 0 }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text("Clipboard")
                .font(.system(size: 13.5, weight: .semibold))
            Text("\(store.items.count)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

            if queueManager.isActive {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Queue: \(queueManager.currentIndex + 1)/\(queueManager.queue.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                    Button {
                        queueManager.stopQueue()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.green.opacity(0.18)))
                .foregroundStyle(Color.green)
            }

            Spacer()

            Button {
                showingNewSnippet = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
            .help("Create a new permanent snippet / template")

            Button {
                actions.mergeRecent()
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Merge recent clips (top 3) into one combined clip")

            Button {
                actions.toggleQueue()
            } label: {
                Image(systemName: queueManager.isActive ? "list.number" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(queueManager.isActive ? Color.green : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(queueManager.isActive ? "Stop Sequential Queue" : "Start Sequential Queue (⌥⌘V to paste next)")

            Button {
                actions.captureScreenText()
            } label: {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
            .help("Extract text from any screen region (⌘⇧2)")

            Button {
                actions.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
            .help("Clear history (keeps pinned items & snippets)")

            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
            .help("Preferences & settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

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

            TextField("Title (e.g. My Bio, Greeting, SQL Query)", text: $snippetTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $snippetText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

            HStack {
                Spacer()
                Button("Cancel") { showingNewSnippet = false }
                    .buttonStyle(.bordered)
                Button("Save Snippet") {
                    actions.createSnippet(snippetTitle, snippetText)
                    snippetTitle = ""
                    snippetText = ""
                    showingNewSnippet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search text, snippets, links, code, or images…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var filterBar: some View {
        HStack(spacing: 3) {
            ForEach(ClipFilter.allCases) { filter in
                let count = count(for: filter)
                let isSelected = state.filter == filter

                Button {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
                        state.filter = filter
                        state.selection = 0
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        if count > 0 && filter != .all {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 0.5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08))
                                )
                        }
                    }
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 5)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                                 )
                                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, x: 0, y: 2)
                                .matchedGeometryEffect(id: "liquidTab", in: tabNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.038))
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func count(for filter: ClipFilter) -> Int {
        switch filter {
        case .all:
            return store.items.count
        case .snippets:
            return store.items.filter { $0.isSnippetItem }.count
        case .text:
            return store.items.filter { $0.kind == .text && !$0.isSnippetItem }.count
        case .images:
            return store.items.filter { $0.kind == .image || ($0.kind == .file && store.ocrURL(for: $0) != nil) }.count
        case .links:
            return store.items.filter { item in
                guard item.kind == .text, let text = item.text else { return false }
                return SmartText.url(from: text) != nil
            }.count
        case .code:
            return store.items.filter { item in
                guard item.kind == .text, let text = item.text else { return false }
                if SmartText.prettyJSON(from: text) != nil { return true }
                let codeKeywords = ["func ", "def ", "class ", "const ", "let ", "var ", "import ", "<?", "<html", "SELECT ", "git ", "npm ", "docker "]
                return codeKeywords.contains { text.contains($0) }
            }.count
        case .pinned:
            return store.items.filter { $0.pinned }.count
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: state.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 38)).foregroundStyle(.tertiary)
            Text(state.query.isEmpty ? "Copy text, images, or screenshots to see them here" : "No matches found")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if state.query.isEmpty {
                Text("Press \(HotkeyPreset.current.title) anywhere to open")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↩", "paste")
            hint("⇧↩", "plain")
            hint("Space", "preview")
            hint("⌥⌘V", "queue")
            hint("⌘E", "OCR")
            hint("⌘P", "pin")
            Spacer()
            Text("Limit: \(Prefs.historyLimit)")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
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

    private var canOCR: Bool { store.ocrURL(for: item) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            meta
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(isSelected: selected, isHovered: hovering, cornerRadius: 11)
        .overlay(alignment: .topTrailing) {
            if hovering || selected { buttons.padding(6) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Paste") { actions.paste(item) }
            Button("Paste as Plain Text (⇧↩)") { actions.pastePlainText(item) }
            Button("Copy Only") { actions.copyOnly(item) }

            if let text = item.text, let url = SmartText.url(from: text) {
                Button("Open Link in Browser (⌘O)") { actions.openURL(url) }
            }
            if canOCR {
                Button("Extract Text (⌘E)") { actions.extractText(item) }
            }
            Button(item.isSnippetItem ? "Remove from Snippets" : "Save as Snippet") {
                actions.toggleSnippet(item)
            }
            Button("Merge Top 3 into One") {
                actions.mergeRecent()
            }
            Button(item.pinned ? "Unpin" : "Pin (⌘P)") { actions.togglePin(item) }
            if item.kind != .text { Button("Show in Finder") { actions.reveal(item) } }
            Divider()
            Button("Quick Look (Space)") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    state.quickLookItem = item
                }
            }
            Divider()
            Button("Delete (⌘⌫)", role: .destructive) { actions.delete(item) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            let textVal = item.text ?? ""
            let sensitive = SmartText.detectSensitive(in: textVal)
            let isMasked = (sensitive != nil) && Prefs.autoMaskSensitive && !isRevealed

            VStack(alignment: .leading, spacing: 4) {
                // Sensitive badge if detected
                if let sensitive {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(sensitive.type)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button {
                            isRevealed.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isRevealed ? "eye.slash" : "eye")
                                Text(isRevealed ? "Hide" : "Reveal")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                }

                // Snippet title badge
                if item.isSnippetItem {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.purple)
                        Text(item.snippetTitle ?? "Template")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                }

                // Color swatch header if it's a hex color
                if let col = SmartText.color(from: textVal) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: col))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                            .shadow(color: Color(nsColor: col).opacity(0.4), radius: 3)
                        Text(SmartText.hexString(from: col))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                // URL indicator
                if let url = SmartText.url(from: textVal) {
                    HStack(spacing: 5) {
                        Image(systemName: "link")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text(url.host ?? "Website")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                // Main Text preview
                Text(isMasked ? (sensitive?.masked ?? item.preview) : item.preview)
                    .font(.system(size: 12.5, design: (isMasked || item.text?.hasPrefix("{") == true) ? .monospaced : .default))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 72)
            }
        case .image:
            thumbnail
        case .file:
            if canOCR {
                thumbnail
            }
            Label(item.preview, systemImage: (item.filePaths?.count ?? 0) > 1 ? "doc.on.doc" : "doc")
                .font(.system(size: 12.5))
                .lineLimit(2)
                .padding(.trailing, 72)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = store.thumbnail(for: item) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 130, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        } else {
            Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary)
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if item.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }
            Image(systemName: kindIcon)
            if let w = item.pixelWidth, let h = item.pixelHeight {
                Text("\(w)×\(h)")
            }
            if let source = item.source {
                Text(source).lineLimit(1)
            }
            Text("·")
            Text(Self.relative.localizedString(for: item.date, relativeTo: Date()))
            if canOCR && item.hasDetectedText {
                Text("Text inside")
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            if let qr = item.qrPayload, !qr.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "qrcode")
                    Text("QR Code")
                }
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
                .foregroundStyle(Color.blue)
            }
            if let text = item.text, SmartText.prettyJSON(from: text) != nil {
                Text("{ } JSON")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)").fontWeight(.medium)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var kindIcon: String {
        if item.isSnippetItem { return "bookmark.fill" }
        switch item.kind {
        case .text:
            if let t = item.text, SmartText.url(from: t) != nil { return "link" }
            return "text.alignleft"
        case .image:
            return item.source == "Screenshot" ? "camera.viewfinder" : "photo"
        case .file:
            return "folder"
        }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            iconButton("eye", help: "Quick Look (Space)") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    state.quickLookItem = item
                }
            }
            if canOCR {
                iconButton("text.viewfinder", help: "Extract text (⌘E)") { actions.extractText(item) }
            }
            iconButton(item.isSnippetItem ? "bookmark.slash" : "bookmark", help: item.isSnippetItem ? "Remove snippet" : "Save as snippet") {
                actions.toggleSnippet(item)
            }
            iconButton(item.pinned ? "pin.slash" : "pin", help: "Pin (⌘P)") { actions.togglePin(item) }
            iconButton("trash", help: "Delete (⌘⌫)") { actions.delete(item) }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        )
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
        .frame(maxWidth: .infinity, maxHeight: 370)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                Color.black.opacity(0.2)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
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
