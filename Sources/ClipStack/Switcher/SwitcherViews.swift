import AppKit
import SwiftUI

struct SwitcherActions {
    var hover: (Int) -> Void
    var activate: (Int) -> Void
    var perform: (WindowSwitcher.Action, Int) -> Void
}

enum SwitcherLayout {
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 14

    static func cellWidth(_ style: SwitcherStyle, _ size: SwitcherSize) -> CGFloat {
        switch style {
        case .thumbnails: return [170, 220, 290][size.rawValue]
        case .appIcons: return [92, 112, 140][size.rawValue]
        case .titles: return [420, 520, 640][size.rawValue]
        }
    }

    static func perRow(count: Int, style: SwitcherStyle, size: SwitcherSize, maxWidth: CGFloat) -> Int {
        guard style != .titles else { return 1 }
        let w = cellWidth(style, size)
        let fit = Int((maxWidth - padding * 2 + spacing) / (w + spacing))
        return max(1, min(count, fit))
    }
}

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    @ObservedObject var settings: SwitcherSettings
    let actions: SwitcherActions
    let maxWidth: CGFloat

    var body: some View {
        let style = settings.style
        let w = SwitcherLayout.cellWidth(style, settings.size)
        let perRow = SwitcherLayout.perRow(count: state.windows.count, style: style, size: settings.size, maxWidth: maxWidth)
        let columns = Array(repeating: GridItem(.fixed(w), spacing: SwitcherLayout.spacing), count: perRow)

        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: style == .titles ? 2 : SwitcherLayout.spacing) {
                        ForEach(Array(state.windows.enumerated()), id: \.element.id) { i, win in
                            cell(win, index: i, width: w)
                                .id(win.id)
                                .onTapGesture { actions.activate(i) }
                                .onHover { if $0 { actions.hover(i) } }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 640)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selection) { _, sel in
                    guard state.windows.indices.contains(sel) else { return }
                    proxy.scrollTo(state.windows[sel].id)
                }
            }

            // App Icons only show the app name per tile; show the selected window's title once below.
            if style == .appIcons, state.windows.indices.contains(state.selection) {
                Text(state.windows[state.selection].displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: CGFloat(perRow) * (w + SwitcherLayout.spacing))
            }

            legend
        }
        .padding(SwitcherLayout.padding)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), fallback: .hudWindow)
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        .padding(30)
    }

    @ViewBuilder
    private func cell(_ win: SwitcherWindow, index i: Int, width: CGFloat) -> some View {
        let selected = i == state.selection
        switch settings.style {
        case .thumbnails:
            ThumbnailCell(window: win, thumbnail: state.thumbnails[win.windowID], selected: selected,
                          width: width, settings: settings, perform: { actions.perform($0, i) })
        case .appIcons:
            IconCell(window: win, selected: selected, width: width, settings: settings)
        case .titles:
            TitleRow(window: win, selected: selected, width: width, settings: settings,
                     perform: { actions.perform($0, i) })
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            key("⇥", "Next"); key("⇧⇥", "Back"); key("W", "Close"); key("M", "Minimize")
            key("F", "Full Screen"); key("H", "Hide"); key("Q", "Quit"); key("esc", "Cancel")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func key(_ k: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(k)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

// MARK: - Shared bits

private struct SelectionBackground: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.24) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.95) : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct StatusBadges: View {
    let window: SwitcherWindow
    @ObservedObject var settings: SwitcherSettings

    var body: some View {
        HStack(spacing: 3) {
            if settings.showSpaceBadge, let s = window.spaceIndex, !window.isOnCurrentSpace {
                Text("\(s)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(.ultraThinMaterial))
                    .help("On Space \(s)")
            }
            if settings.showStatusBadges {
                if window.isMinimized { badge("minus", "Minimized") }
                if window.isAppHidden { badge("eye.slash", "App hidden") }
                if window.isFullscreen { badge("arrow.up.left.and.arrow.down.right", "Full screen") }
                if window.isWindowless { badge("square.dashed", "No open windows") }
            }
        }
    }

    private func badge(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8.5, weight: .bold))
            .frame(width: 16, height: 16)
            .background(Circle().fill(.ultraThinMaterial))
            .help(help)
    }
}

private struct TrafficLights: View {
    let window: SwitcherWindow
    let perform: (WindowSwitcher.Action) -> Void

    var body: some View {
        HStack(spacing: 5) {
            light(.red, "xmark") { perform(.close) }
            light(.yellow, "minus") { perform(.minimize) }
            light(.green, window.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                perform(.fullscreen)
            }
        }
    }

    private func light(_ color: Color, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 6.5, weight: .black))
                .foregroundStyle(.black.opacity(0.55))
                .frame(width: 13, height: 13)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Thumbnails style

private struct ThumbnailCell: View {
    let window: SwitcherWindow
    let thumbnail: NSImage?
    let selected: Bool
    let width: CGFloat
    @ObservedObject var settings: SwitcherSettings
    let perform: (WindowSwitcher.Action) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .padding(5)
                        .opacity(window.isMinimized || window.isAppHidden ? 0.55 : 1)
                } else if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: width * 0.28, height: width * 0.28)
                }
            }
            .frame(height: width * 0.6)
            .overlay(alignment: .topLeading) {
                if hovering && !window.isWindowless { TrafficLights(window: window, perform: perform).padding(7) }
            }
            .overlay(alignment: .topTrailing) {
                StatusBadges(window: window, settings: settings).padding(6)
            }

            HStack(spacing: 6) {
                if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.displayTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if settings.showAppName && !window.title.isEmpty {
                        Text(window.appName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(7)
        .frame(width: width)
        .modifier(SelectionBackground(selected: selected, radius: 13))
        .onHover { hovering = $0 }
    }
}

// MARK: - App icons style

private struct IconCell: View {
    let window: SwitcherWindow
    let selected: Bool
    let width: CGFloat
    @ObservedObject var settings: SwitcherSettings

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: width * 0.66, height: width * 0.66)
                        .opacity(window.isMinimized || window.isAppHidden ? 0.6 : 1)
                }
                StatusBadges(window: window, settings: settings).offset(x: 6, y: -4)
            }
            if settings.showAppName {
                Text(window.appName)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(8)
        .frame(width: width)
        .modifier(SelectionBackground(selected: selected, radius: 16))
        .help(window.displayTitle)
    }
}

// MARK: - Titles style

private struct TitleRow: View {
    let window: SwitcherWindow
    let selected: Bool
    let width: CGFloat
    @ObservedObject var settings: SwitcherSettings
    let perform: (WindowSwitcher.Action) -> Void
    @State private var hovering = false

    var body: some View {
        let h: CGFloat = [30, 36, 44][settings.size.rawValue]
        HStack(spacing: 10) {
            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: h * 0.7, height: h * 0.7) }
            Text(window.displayTitle)
                .font(.system(size: h * 0.36, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            if settings.showAppName && !window.title.isEmpty {
                Text(window.appName)
                    .font(.system(size: h * 0.3))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering && !window.isWindowless { TrafficLights(window: window, perform: perform) }
            StatusBadges(window: window, settings: settings)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: h)
        .modifier(SelectionBackground(selected: selected, radius: 9))
        .onHover { hovering = $0 }
    }
}

// MARK: - Selected-window preview

struct PreviewView: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .opacity(0.92)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 3))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
