import AppKit
import SwiftUI
import Carbon.HIToolbox

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case text = "Text"
    case images = "Images"
    case pinned = "Pinned"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .images: return "photo"
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

    func filtered(_ items: [ClipItem]) -> [ClipItem] {
        var list = items
        switch filter {
        case .all:
            break
        case .text:
            list = list.filter { $0.kind == .text }
        case .images:
            list = list.filter { item in
                item.kind == .image || (item.kind == .file && ClipboardStore.shared.ocrURL(for: item) != nil)
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
    var copyOnly: (ClipItem) -> Void
    var togglePin: (ClipItem) -> Void
    var delete: (ClipItem) -> Void
    var extractText: (ClipItem) -> Void
    var reveal: (ClipItem) -> Void
    var clear: () -> Void
    var captureScreenText: () -> Void
    var openSettings: (NSView?) -> Void
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        minSize = NSSize(width: 350, height: 400)
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
    let state = PanelState()
    var onOpenSettings: ((NSView?) -> Void)?
    private var panel: FloatingPanel!
    private var keyMonitor: Any?

    init(store: ClipboardStore) {
        self.store = store
        panel = FloatingPanel(size: NSSize(width: 390, height: 560))
        panel.onResignKey = { [weak self] in self?.hide() }

        let actions = PanelActions(
            paste: { [weak self] in self?.paste($0) },
            copyOnly: { [weak self] in self?.copyOnly($0) },
            togglePin: { [weak self] in self?.store.togglePin($0) },
            delete: { [weak self] in self?.store.delete($0) },
            extractText: { [weak self] in self?.extractText($0) },
            reveal: { [weak self] in self?.reveal($0) },
            clear: { [weak self] in self?.store.clearUnpinned() },
            captureScreenText: { ScreenTextCapture.start() },
            openSettings: { [weak self] view in self?.onOpenSettings?(view) }
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
        state.scrollTarget = store.items.first?.id
        position(nearItem: nearItem, nearMouse: nearMouse)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        state.focusToken += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
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
            if origin.y < vf.minY { origin.y = mouse.y + 12 } // flip above cursor if near bottom
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
        let count = visibleItems.count

        // ⌘1 … ⌘9 → paste that item
        if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            let items = visibleItems
            if items.indices.contains(n - 1) { paste(items[n - 1]) }
            return true
        }

        switch Int(e.keyCode) {
        case kVK_Escape:
            if state.query.isEmpty { hide() } else { state.query = "" }
            return true
        case kVK_DownArrow:
            move(by: 1, count: count); return true
        case kVK_UpArrow:
            move(by: -1, count: count); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = selectedItem { paste(item) }
            return true
        case kVK_Delete where cmd, kVK_ForwardDelete where cmd:
            if let item = selectedItem { store.delete(item) }
            return true
        case kVK_ANSI_P where cmd:
            if let item = selectedItem { store.togglePin(item) }
            return true
        case kVK_ANSI_E where cmd:
            if let item = selectedItem { extractText(item) }
            return true
        case kVK_ANSI_C where cmd && state.query.isEmpty:
            if let item = selectedItem { copyOnly(item) }
            return true
        case kVK_Space where state.query.isEmpty:
            if let item = selectedItem {
                if let url = store.ocrURL(for: item) {
                    NSWorkspace.shared.open(url)
                    return true
                }
            }
            return false
        default:
            return false
        }
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        state.selection = min(max(state.selection + delta, 0), count - 1)
        state.scrollTarget = visibleItems[state.selection].id
    }

    // MARK: - Actions

    private func paste(_ item: ClipItem) {
        store.copyToPasteboard(item)
        hide()
        guard Prefs.autoPaste else { HUD.show("Copied"); return }
        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Paster.pasteCommandV() }
        } else {
            HUD.show("Copied — press ⌘V to paste")
        }
    }

    private func copyOnly(_ item: ClipItem) {
        store.copyToPasteboard(item)
        hide()
        HUD.show("Copied")
    }

    private func extractText(_ item: ClipItem) {
        guard store.ocrURL(for: item) != nil else {
            HUD.show("Not an image", symbol: "exclamationmark.triangle.fill")
            return
        }
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

    private func reveal(_ item: ClipItem) {
        let url: URL? = item.kind == .file ? item.filePaths?.first.map { URL(fileURLWithPath: $0) } : store.imageURL(for: item)
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        hide()
    }
}

// MARK: - Views

struct HistoryView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: PanelState
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = state.filtered(store.items)
        let selection = items.isEmpty ? -1 : min(state.selection, items.count - 1)

        VStack(spacing: 0) {
            header
            searchField
            filterBar
            Divider().opacity(0.12)
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, index: index, selected: index == selection,
                                        store: store, actions: actions)
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
        .frame(minWidth: 350, minHeight: 400)
        .background(VisualEffect(material: .popover).ignoresSafeArea())
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onChange(of: state.query) { _, _ in state.selection = 0 }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 14))
            Text("Clipboard")
                .font(.system(size: 13.5, weight: .semibold))
            Text("\(store.items.count)")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

            Spacer()

            Button {
                actions.captureScreenText()
            } label: {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Extract text from any screen region (⌘⇧2)")

            Button {
                actions.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Clear history (keeps pinned items)")

            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Preferences & settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search text or words inside images…", text: $state.query)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(ClipFilter.allCases) { filter in
                let count = count(for: filter)
                Button {
                    state.filter = filter
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 10))
                        Text(filter.rawValue)
                        if count > 0 && filter != .all {
                            Text("\(count)")
                                .font(.system(size: 9.5, weight: .bold))
                                .opacity(0.8)
                        }
                    }
                    .font(.system(size: 11, weight: state.filter == filter ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(state.filter == filter ? Color.accentColor : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(state.filter == filter ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func count(for filter: ClipFilter) -> Int {
        switch filter {
        case .all:
            return store.items.count
        case .text:
            return store.items.filter { $0.kind == .text }.count
        case .images:
            return store.items.filter { $0.kind == .image || ($0.kind == .file && store.ocrURL(for: $0) != nil) }.count
        case .pinned:
            return store.items.filter { $0.pinned }.count
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: state.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
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
            hint("⌘E", "extract text")
            hint("⌘P", "pin")
            hint("⌘⌫", "delete")
            Spacer()
            Text("Limit: \(Prefs.historyLimit)")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    @ObservedObject var store: ClipboardStore
    let actions: PanelActions
    @State private var hovering = false

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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering || selected { buttons.padding(6) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Paste") { actions.paste(item) }
            Button("Copy") { actions.copyOnly(item) }
            if canOCR { Button("Extract Text") { actions.extractText(item) } }
            Button(item.pinned ? "Unpin" : "Pin") { actions.togglePin(item) }
            if item.kind != .text { Button("Show in Finder") { actions.reveal(item) } }
            Divider()
            Button("Delete", role: .destructive) { actions.delete(item) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.preview)
                .font(.system(size: 12.5))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 72)
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
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
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)").fontWeight(.medium)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var kindIcon: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .image: return item.source == "Screenshot" ? "camera.viewfinder" : "photo"
        case .file: return "folder"
        }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            if canOCR {
                iconButton("text.viewfinder", help: "Extract text (⌘E)") { actions.extractText(item) }
            }
            iconButton(item.pinned ? "pin.slash" : "pin", help: "Pin (⌘P)") { actions.togglePin(item) }
            iconButton("trash", help: "Delete (⌘⌫)") { actions.delete(item) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
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
