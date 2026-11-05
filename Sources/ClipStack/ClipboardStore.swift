import AppKit
import CryptoKit
import ImageIO

struct ClipItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, file }

    var id: UUID
    var kind: Kind
    var text: String?
    var imageFile: String?      // file name inside the images folder
    var filePaths: [String]?    // for copied Finder files
    var hash: String
    var date: Date
    var pinned: Bool
    var source: String?
    var ocrText: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var isSnippet: Bool?
    var snippetTitle: String?
    var qrPayload: String?

    var isSnippetItem: Bool { isSnippet ?? false }
    var hasQRPayload: Bool { !(qrPayload ?? "").isEmpty }

    init(id: UUID = UUID(), kind: Kind, text: String? = nil, imageFile: String? = nil,
         filePaths: [String]? = nil, hash: String, date: Date = Date(), pinned: Bool = false,
         source: String? = nil, ocrText: String? = nil, pixelWidth: Int? = nil,
         pixelHeight: Int? = nil, isSnippet: Bool? = false, snippetTitle: String? = nil,
         qrPayload: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.filePaths = filePaths
        self.hash = hash
        self.date = date
        self.pinned = pinned
        self.source = source
        self.ocrText = ocrText
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isSnippet = isSnippet
        self.snippetTitle = snippetTitle
        self.qrPayload = qrPayload
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFile, filePaths, hash, date, pinned, source, ocrText, pixelWidth, pixelHeight, isSnippet, snippetTitle, qrPayload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths)
        hash = try c.decode(String.self, forKey: .hash)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        isSnippet = try c.decodeIfPresent(Bool.self, forKey: .isSnippet) ?? false
        snippetTitle = try c.decodeIfPresent(String.self, forKey: .snippetTitle)
        qrPayload = try c.decodeIfPresent(String.self, forKey: .qrPayload)
    }

    var preview: String {
        switch kind {
        case .text:
            return String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        case .image:
            return "Image"
        case .file:
            return (filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    var searchText: String {
        [text, ocrText, filePaths?.joined(separator: " "), source, snippetTitle, qrPayload]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var hasDetectedText: Bool { !(ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    @Published private(set) var items: [ClipItem] = []

    let baseDir: URL
    let imagesDir: URL
    private let historyURL: URL
    private var lastChangeCount: Int
    private var timer: Timer?
    private let thumbCache = NSCache<NSString, NSImage>()

    private init() {
        let fm = FileManager.default
        baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipStack", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        historyURL = baseDir.appendingPathComponent("history.json")
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        lastChangeCount = NSPasteboard.general.changeCount
        load()
    }

    // MARK: - Monitoring

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        capture(from: pb)
    }

    private func capture(from pb: NSPasteboard) {
        let types = pb.types ?? []
        let raw = Set(types.map(\.rawValue))

        // Respect password managers & apps that mark data as private/transient.
        let privateMarkers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                              "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        if privateMarkers.contains(where: raw.contains) { return }

        let source = NSWorkspace.shared.frontmostApplication?.localizedName

        // 1. Files copied in Finder
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addFiles(urls, source: source)
            return
        }

        // 2. Images vs. text
        let string = pb.string(forType: .string)
        let hasText = !(string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasRichText = types.contains(.rtf) || types.contains(.rtfd)
        let hasImage = types.contains(.png) || types.contains(.tiff)

        // Rich text apps (Word, Excel, Pages…) also put an image preview on the
        // clipboard; prefer the text in that case.
        if hasImage && (!hasText || !hasRichText),
           let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let png = Self.pngData(from: data) {
            addImage(png: png, source: source)
            return
        }

        if hasText, let string {
            addText(string, source: source)
        }
    }

    // MARK: - Adding

    @discardableResult
    func addText(_ text: String, source: String?) -> ClipItem {
        let hash = Self.sha("t:" + text)
        if let existing = bump(hash: hash) { return existing }
        let item = ClipItem(kind: .text, text: text, hash: hash, source: source)
        insert(item)
        return item
    }

    @discardableResult
    func addImage(png: Data, source: String?) -> ClipItem {
        let hash = Self.sha(png)
        if let existing = bump(hash: hash) { return existing }

        let name = UUID().uuidString + ".png"
        try? png.write(to: imagesDir.appendingPathComponent(name))
        let rep = NSBitmapImageRep(data: png)
        let item = ClipItem(kind: .image, imageFile: name, hash: hash, source: source,
                            pixelWidth: rep?.pixelsWide, pixelHeight: rep?.pixelsHigh)
        insert(item)
        runOCRInBackground(item)
        return item
    }

    @discardableResult
    func addImage(fileURL: URL, source: String?) -> ClipItem? {
        guard let data = try? Data(contentsOf: fileURL), let png = Self.pngData(from: data) else { return nil }
        return addImage(png: png, source: source)
    }

    private func addFiles(_ urls: [URL], source: String?) {
        let paths = urls.map(\.path)
        let hash = Self.sha("f:" + paths.joined(separator: "\n"))
        if bump(hash: hash) != nil { return }
        let item = ClipItem(kind: .file, filePaths: paths, hash: hash, source: source)
        insert(item)
        if ocrURL(for: item) != nil { runOCRInBackground(item) }
    }

    /// If an item with this hash exists, move it to the top and return it.
    private func bump(hash: String) -> ClipItem? {
        guard let idx = items.firstIndex(where: { $0.hash == hash }) else { return nil }
        var item = items.remove(at: idx)
        item.date = Date()
        items.insert(item, at: 0)
        save()
        return item
    }

    private func insert(_ item: ClipItem) {
        items.insert(item, at: 0)
        trim()
        save()
    }

    private func trim() {
        let limit = Prefs.historyLimit
        while items.filter({ !$0.pinned }).count > limit,
              let idx = items.lastIndex(where: { !$0.pinned }) {
            removeFiles(of: items[idx])
            items.remove(at: idx)
        }
    }

    func applyLimit() {
        trim()
        save()
    }

    // MARK: - Actions

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = imageURL(for: item), let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .file:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
            if let first = item.filePaths?.first, item.filePaths?.count == 1,
               Self.imageExtensions.contains((first as NSString).pathExtension.lowercased()),
               let data = try? Data(contentsOf: URL(fileURLWithPath: first)),
               let png = Self.pngData(from: data) {
                pb.setData(png, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        }
        lastChangeCount = pb.changeCount
        _ = bump(hash: item.hash)
        SoundEffects.playCopy()
    }

    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].pinned.toggle()
        trim()
        save()
    }

    func delete(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        removeFiles(of: items[idx])
        items.remove(at: idx)
        save()
    }

    /// Clears everything except pinned items.
    func clearUnpinned() {
        for item in items where !item.pinned { removeFiles(of: item) }
        items.removeAll { !$0.pinned }
        save()
    }

    // MARK: - Snippets

    @discardableResult
    func createSnippet(title: String, text: String) -> ClipItem {
        let hash = Self.sha("snippet:\(UUID().uuidString):\(text)")
        var item = ClipItem(kind: .text, text: text, hash: hash, source: "Snippet")
        item.isSnippet = true
        item.snippetTitle = title
        item.pinned = true
        insert(item)
        return item
    }

    func toggleSnippet(_ item: ClipItem, title: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let current = items[idx].isSnippetItem
        items[idx].isSnippet = !current
        if !current {
            items[idx].pinned = true
            if let title = title, !title.isEmpty {
                items[idx].snippetTitle = title
            } else if items[idx].snippetTitle == nil {
                let sample = (items[idx].text ?? items[idx].ocrText ?? "Snippet").trimmingCharacters(in: .whitespacesAndNewlines)
                items[idx].snippetTitle = String(sample.prefix(25))
            }
        }
        save()
    }

    // MARK: - Image Updates

    func updateImageData(for item: ClipItem, pngData: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }),
              let fileName = items[idx].imageFile else { return }
        let fileURL = imagesDir.appendingPathComponent(fileName)
        try? pngData.write(to: fileURL)
        let rep = NSBitmapImageRep(data: pngData)
        items[idx].pixelWidth = rep?.pixelsWide
        items[idx].pixelHeight = rep?.pixelsHigh
        thumbCache.removeObject(forKey: item.id.uuidString as NSString)
        save()
    }

    // MARK: - Export

    func exportHistory(to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        try data.write(to: destinationURL)
    }

    func exportAsMarkdown(to destinationURL: URL) throws {
        var lines: [String] = ["# ClipStack Clipboard Export", "Date: \(Date().formatted())", "Total items: \(items.count)", ""]
        for (i, item) in items.enumerated() {
            let title = item.isSnippetItem ? "[SNIPPET: \(item.snippetTitle ?? "Template")]" : (item.source != nil ? "[\(item.source!)]" : "[\(item.kind.rawValue.uppercased())]")
            lines.append("### \(i + 1). \(title) - \(item.date.formatted())")
            if let text = item.text {
                lines.append("```\n\(text)\n```")
            } else if let ocr = item.ocrText, !ocr.isEmpty {
                lines.append("**Extracted Text (OCR):**\n```\n\(ocr)\n```")
            } else if let paths = item.filePaths {
                lines.append("**Files:**\n" + paths.map { "- \($0)" }.joined(separator: "\n"))
            }
            if let qr = item.qrPayload {
                lines.append("**QR / Barcode Payload:** `\(qr)`")
            }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    // MARK: - OCR & Vision Analysis

    /// Image URL usable for OCR (clipboard images or a single copied image file).
    func ocrURL(for item: ClipItem) -> URL? {
        switch item.kind {
        case .image: return imageURL(for: item)
        case .file:
            guard let paths = item.filePaths, paths.count == 1,
                  Self.imageExtensions.contains((paths[0] as NSString).pathExtension.lowercased()) else { return nil }
            return URL(fileURLWithPath: paths[0])
        case .text: return nil
        }
    }

    func recognizedText(for item: ClipItem) async -> String {
        if let current = items.first(where: { $0.id == item.id }), let t = current.ocrText { return t }
        guard let url = ocrURL(for: item) else { return "" }
        let res = await OCR.analyze(url: url)
        setAnalysis(text: res.text, qrPayload: res.qrPayload, for: item.id)
        return res.text
    }

    private func runOCRInBackground(_ item: ClipItem) {
        guard let url = ocrURL(for: item) else { return }
        Task { [weak self] in
            let res = await OCR.analyze(url: url)
            self?.setAnalysis(text: res.text, qrPayload: res.qrPayload, for: item.id)
        }
    }

    private func setAnalysis(text: String, qrPayload: String?, for id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].ocrText = text
        if let qr = qrPayload, !qr.isEmpty {
            items[idx].qrPayload = qr
        }
        save()
    }

    // MARK: - Images

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let url = ocrURL(for: item),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    private func removeFiles(of item: ClipItem) {
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
        thumbCache.removeObject(forKey: item.id.uuidString as NSString)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    // MARK: - Helpers

    static func pngData(from data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func sha(_ string: String) -> String { sha(Data(string.utf8)) }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
