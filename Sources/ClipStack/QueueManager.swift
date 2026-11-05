import AppKit
import Foundation

@MainActor
final class QueueManager: ObservableObject {
    static let shared = QueueManager()

    @Published private(set) var isActive = false
    @Published private(set) var queue: [ClipItem] = []
    @Published private(set) var currentIndex = 0

    private init() {}

    func startQueue(with items: [ClipItem]) {
        guard !items.isEmpty else {
            HUD.show("No items to queue", symbol: "exclamationmark.triangle")
            return
        }
        // Sequential paste is FIFO: older to newer (or top to bottom as selected)
        queue = items
        currentIndex = 0
        isActive = true
        Haptics.click()
        showCurrentHUD()
    }

    func stopQueue() {
        guard isActive else { return }
        isActive = false
        queue.removeAll()
        currentIndex = 0
        Haptics.tap()
        HUD.show("Queue stopped", symbol: "stop.circle")
    }

    /// Advances to the next item and pastes it
    func pasteNext() {
        guard isActive, !queue.isEmpty else { return }
        let item = queue[currentIndex]
        ClipboardStore.shared.copyToPasteboard(item)
        Haptics.click()

        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                Paster.pasteCommandV()
            }
        }

        currentIndex += 1
        if currentIndex >= queue.count {
            isActive = false
            queue.removeAll()
            currentIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                HUD.show("Queue completed! 🎉", symbol: "checkmark.circle.fill")
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showCurrentHUD()
            }
        }
    }

    private func showCurrentHUD() {
        guard currentIndex < queue.count else { return }
        let current = queue[currentIndex]
        let preview = current.preview.replacingOccurrences(of: "\n", with: " ")
        let shortText = preview.count > 25 ? String(preview.prefix(25)) + "…" : preview
        HUD.show("Queue [\(currentIndex + 1)/\(queue.count)]: \"\(shortText)\"", symbol: "list.number")
    }
}

