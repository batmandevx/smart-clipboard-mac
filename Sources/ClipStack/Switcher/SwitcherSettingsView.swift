import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Preferences window for the window switcher.
@MainActor
enum SwitcherSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Window Switcher"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SwitcherSettingsView(settings: .shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SwitcherSettingsView: View {
    @ObservedObject var settings: SwitcherSettings
    @State private var trusted = AXIsProcessTrusted()
    @State private var screenRec = CGPreflightScreenCaptureAccess()

    var body: some View {
        TabView {
            controls.tabItem { Label("Controls", systemImage: "keyboard") }
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            filters.tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            ExclusionsView(settings: settings).tabItem { Label("Exclusions", systemImage: "nosign") }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXIsProcessTrusted()
            screenRec = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            permissionRows

            Section("Shortcut") {
                Picker("Hold", selection: $settings.holdModifier) {
                    ForEach(HoldModifier.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Quick tap switches instantly (no flash)", isOn: $settings.quickTapSwitches)
                if settings.quickTapSwitches {
                    Picker("Show switcher after", selection: $settings.delayMs) {
                        Text("0 ms").tag(0); Text("80 ms").tag(80); Text("120 ms").tag(120)
                        Text("200 ms").tag(200); Text("300 ms").tag(300)
                    }
                }
            }

            shortcutSection(title: "\(settings.holdModifier.symbol) Tab", config: $settings.shortcut1)
            shortcutSection(title: "\(settings.holdModifier.symbol) `  (key above Tab)", config: $settings.shortcut2)

            Section("Mouse & focus") {
                Toggle("Hovering selects a window", isOn: $settings.mouseHoverSelects)
                Toggle("Move cursor to the focused window", isOn: $settings.cursorFollowsFocus)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutSection(title: String, config: Binding<ShortcutConfig>) -> some View {
        Section(title) {
            Toggle("Enabled", isOn: config.enabled)
            Picker("Show windows from", selection: config.apps) {
                ForEach(AppsScope.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Spaces", selection: config.spaces) {
                ForEach(SpacesScope.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Screens", selection: config.screens) {
                ForEach(ScreensScope.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
    }

    @ViewBuilder
    private var permissionRows: some View {
        if !trusted || !screenRec {
            Section("Permissions") {
                if !trusted {
                    HStack {
                        Label("Accessibility is required to switch windows", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                }
                if !screenRec {
                    HStack {
                        Label("Screen Recording enables thumbnails & titles", systemImage: "photo")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            _ = CGRequestScreenCaptureAccess()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        }
                    }
                }
            }
        }
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    // MARK: Appearance

    private var appearance: some View {
        Form {
            Section("Style") {
                Picker("Style", selection: $settings.style) {
                    ForEach(SwitcherStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: $settings.size) {
                    ForEach(SwitcherSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Show on", selection: $settings.showOn) {
                    ForEach(ShowOnScreen.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Details") {
                Toggle("Preview the selected window in place", isOn: $settings.previewSelected)
                Toggle("Show app name", isOn: $settings.showAppName)
                Toggle("Show Space number for windows on other Spaces", isOn: $settings.showSpaceBadge)
                Toggle("Show minimized / hidden / full-screen badges", isOn: $settings.showStatusBadges)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Filters

    private var filters: some View {
        Form {
            Section("Include") {
                Toggle("Minimized windows", isOn: $settings.showMinimized)
                Toggle("Windows of hidden apps", isOn: $settings.showHidden)
                Toggle("Full-screen windows", isOn: $settings.showFullscreen)
                Toggle("Apps with no open windows", isOn: $settings.showWindowless)
            }
            Section("Order") {
                Picker("Sort windows by", selection: $settings.order) {
                    ForEach(WindowOrder.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Exclusions

private struct ExclusionsView: View {
    @ObservedObject var settings: SwitcherSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hide an app's windows from the switcher, or let it keep the shortcut for itself (games, VMs, remote desktops).")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach($settings.exclusions) { $ex in
                    HStack {
                        appLabel(ex.bundleID)
                        Spacer()
                        Picker("", selection: $ex.mode) {
                            ForEach(ExclusionMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                        Button {
                            settings.exclusions.removeAll { $0.bundleID == ex.bundleID }
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if settings.exclusions.isEmpty {
                    Text("No excluded apps").foregroundStyle(.tertiary)
                }
            }

            HStack {
                Button("Add App…", action: addApp)
                Menu("Add Running App") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil },
                            id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) { add(app.bundleIdentifier!) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func appLabel(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        return HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            }
            Text(name.replacingOccurrences(of: ".app", with: "")).lineLimit(1)
        }
    }

    private func add(_ bundleID: String) {
        guard !settings.exclusions.contains(where: { $0.bundleID == bundleID }) else { return }
        settings.exclusions.append(Exclusion(bundleID: bundleID, mode: .hideWindows))
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}
