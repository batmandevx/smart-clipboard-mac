<div align="center">

<img src="docs/assets/banner.svg" alt="ClipStack Banner" width="100%" />

<br/>

[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B%20(Sonoma%2FSequoia)-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9%2B-FA7343?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/Architecture-Apple%20Silicon%20%7C%20Intel-0284C7?style=for-the-badge)](https://apple.com)
[![Vision OCR](https://img.shields.io/badge/OCR-Apple%20Vision%20(Offline)-10B981?style=for-the-badge)](https://developer.apple.com/documentation/vision)
[![License](https://img.shields.io/badge/License-MIT-6366F1?style=for-the-badge)](LICENSE)

<p align="center">
  <b>A native macOS clipboard manager &amp; productivity toolbox with Apple Liquid Glass UI, fluid spring physics, on-device Vision OCR, and sequential queue paste.</b>
</p>

[Key Features](#-key-features) • [UI &amp; Visual Showcase](#-interface-showcase) • [Architecture](#-system-architecture) • [Keyboard Shortcuts](#-keyboard-shortcuts) • [Install &amp; Run](#-installation--quick-start)

</div>

---

## 💡 The Story

Coming from Windows, many power users miss two essential built-in workflows:
1. **Windows Clipboard History (`Win + V`)**: Accessing past copies without losing history when copying new items.
2. **PowerToys / Snipping Tool Text Extractor**: Dragging a box over any image, video frame, or unselectable text on screen to instantly OCR and copy it.

**ClipStack** brings these capabilities natively to macOS, supercharged with Apple's **Vision neural framework** and wrapped in an ultra-smooth **Liquid Glass design** with haptic feedback.

---

## 🔮 Interface Showcase

<div align="center">
  <img src="docs/assets/interface_preview.svg" alt="ClipStack Liquid Glass Interface" width="85%" />
</div>

---

## ✨ Key Features

### 1. Never Overwrite Copied Items
- Automatically stores copied text, rich text, images, screenshots, and Finder files.
- Configurable history retention: **20, 50, 100, 200, or 500 items**.
- **Pin Items (`⌘P`)**: Keep important snippets permanently in your stack so they never get pruned.

### 2. Apple Vision Framework On-Device OCR (100% Offline & Private)
- **Automatic Background OCR**: When you copy any photo, screenshot, or image file, Apple Vision analyzes it on the neural engine.
- **Search Inside Images**: Search for words that exist *inside* your screenshots to find images immediately.
- **Extract Text Shortcut (`⌘E`)**: One-key extraction from any image into clean editable text.
- **Screen Region Text Extractor (`⌘⇧2`)**: Drag-select any portion of your screen (videos, PDFs, apps) to instantly extract text.

### 3. Sequential Paste / Queue Mode (`⌥⌘V`)
- Need to copy 5 fields from a spreadsheet and paste them one by one into a form?
- Enter **Queue Mode** (`⌥Q` or Menu), copy your items, and press **`⌥⌘V`** repeatedly. ClipStack pastes each item in sequential order (FIFO) with a live HUD counter!

### 4. Smart Content Intelligence & Quick Look (`Space`)
Press **`Space`** on any item to slide open the integrated **Liquid Glass Quick Look Drawer**:
- **Hex Color Swatches**: Live color previews for hex codes (`#6366F1`) and RGB with one-click copying.
- **URL & Domain Detection**: Domain detection, favicon tags, and direct **Open in Browser (`⌘O`)**.
- **JSON Beautify / Minify**: One-click format and indent minified JSON strings.
- **Case Converters**: Transform text instantly to `UPPERCASE`, `lowercase`, `Title Case`, `camelCase`, `snake_case`, or `kebab-case`.
- **Developer Tools**: `Base64 Encode/Decode`, `URL Encode/Decode`, `Strip HTML`, and `Strip Markdown`.
- **Text Statistics**: Real-time word count, character count, and line count.

### 5. Categorized Filtering with Liquid Tabs
- Filter tabs: **All**, **Text**, **Images**, **Links**, **Code**, and **Pinned**.
- Powered by SwiftUI `matchedGeometryEffect` fluid spring animations that glide across tabs like liquid.

### 6. Export & Backup
- Export your entire clipboard history anytime as formatted **Markdown (`.md`)** or **JSON (`.json`)**.

---

## 📊 Feature Comparison

| Capability | macOS Default | Windows 11 (Win+V) | Maccy | Paste App | **ClipStack** |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Clipboard History Stack** | ❌ (1 item only) | ✅ (25 items) | ✅ | ✅ | **✅ (Up to 500)** |
| **Photo & Screenshot Support** | ❌ | ✅ | ⚠️ Basic | ✅ | **✅ Full Retina** |
| **Search Inside Images (OCR)** | ❌ | ❌ | ❌ | ❌ | **✅ Apple Vision** |
| **Interactive Screen OCR** | ❌ | ⚠️ PowerToys | ❌ | ❌ | **✅ Built-in (`⌘⇧2`)** |
| **Sequential Paste (Queue Mode)** | ❌ | ❌ | ❌ | ❌ | **✅ Built-in (`⌥⌘V`)** |
| **Smart Text Transforms (JSON/Case)** | ❌ | ❌ | ❌ | ⚠️ Limited | **✅ Full Suite** |
| **Color Swatch Preview** | ❌ | ❌ | ❌ | ✅ | **✅ Live Swatch** |
| **Liquid Glass Design & Haptics** | ❌ | ❌ | ❌ | ⚠️ Custom | **✅ Native Liquid Glass** |
| **Zero Subscriptions / 100% Free** | ✅ | ✅ | ✅ | ❌ ($14.99/yr) | **✅ 100% Free & Open** |

---

## 🏗️ System Architecture

ClipStack is built with modern **Swift 5.9**, **SwiftUI**, **AppKit**, and **Apple's Vision Framework**.

```mermaid
flowchart TD
    subgraph Inputs ["1. Ingestion Layer"]
        PB["NSPasteboard Polling (0.35s)"]
        SW["ScreenshotWatcher (Desktop/Custom Folder)"]
        SE["ScreenTextCapture (screencapture -i)"]
    end

    subgraph Security ["2. Privacy Shield"]
        PM["Concealed / Transient Type Filter"]
        PWD["Password Manager Exclusion (1Password, Bitwarden)"]
    end

    subgraph Intelligence ["3. Intelligence Engine"]
        VIS["Apple Vision OCR (VNRecognizeTextRequest)"]
        SMT["SmartText Analyzer (Colors, URLs, JSON, Code)"]
        TRF["Transformations Engine (Case, Base64, Strip)"]
    end

    subgraph Core ["4. Core Management"]
        CS["ClipboardStore (MainActor ObservableObject)"]
        QM["QueueManager (Sequential FIFO Paste)"]
        PR["Prefs (UserDefaults + HotkeyPresets)"]
        DB[("Atomic SSD Storage (history.json + /images)")]
    end

    subgraph Output ["5. Execution & Presentation"]
        HK["Carbon EventHotKeys (⌘⇧V, ⌘⇧2, ⌥⌘V)"]
        AX["Paster Engine (CGEvent Synthetic Keypress)"]
        HUD_UI["HUD Notification System (Visual Effect Toast)"]
        UI["Liquid Glass Floating Panel (SwiftUI + AppKit)"]
    end

    PB --> PM --> CS
    SW --> VIS --> CS
    SE --> VIS --> CS
    CS --> SMT
    SMT --> TRF
    CS <--> DB
    CS <--> QM
    HK --> UI
    HK --> QM
    QM --> AX
    UI --> AX
    UI --> HUD_UI
    TRF --> CS
```

---

### Sequential Paste (Queue Mode) Workflow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant CS as ClipStack
    participant QM as QueueManager
    participant Target as Active App

    User->>CS: Start Queue Mode (⌥Q or Menu)
    CS->>QM: Enqueue items [Field 1, Field 2, Field 3]
    QM-->>User: HUD: Queue [1/3] "First Item"

    loop For each item
        User->>QM: Press ⌥⌘V
        QM->>CS: Copy queue[index] to NSPasteboard
        QM->>Target: Synthetic ⌘V Keypress (CGEvent)
        Target-->>User: Inserts field
        QM-->>User: HUD: Queue [index/total] "Next Item"
    end

    QM-->>User: HUD: Queue completed! 🎉
```

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Description |
| :--- | :--- |
| **`⌘⇧V`** | Toggle ClipStack Clipboard History popup (customizable: `⌥V`, `⌃⌥V`, etc.) |
| **`⌘⇧2`** | Interactive Screen Text Extractor (drag region & OCR to clipboard) |
| **`⌥⌘V`** | Paste next item in Sequential Queue Mode |
| **`Space`** | **Toggle Quick Look preview drawer & text tools** |
| **`↩ (Return)`** | Paste selected item into active application |
| **`⇧↩ (Shift+Return)`** | **Paste as clean Plain Text (strips formatting & line breaks)** |
| **`⌘1` … `⌘9`** | Instant-paste items 1 through 9 |
| **`⌘O`** | Open selected link directly in default browser |
| **`⌘E`** | Extract text from selected image |
| **`⌘P`** | Pin / unpin selected item |
| **`⌘⌫`** | Delete selected item |
| **`Esc`** | Close Quick Look drawer / clear search / dismiss window |

---

## 🚀 Installation & Quick Start

### Option 1: Automatic Build & Install (Recommended)
Clone the repository and run the build script:
```bash
git clone https://github.com/batmandevx/smart-clipboard-mac.git
cd smart-clipboard-mac
chmod +x build.sh
./build.sh install
```
This compiles the release binary, signs it, installs it into `/Applications/ClipStack.app`, and launches it immediately.

### Option 2: Build Locally without Installing
```bash
./build.sh
open build/ClipStack.app
```

---

## ⚙️ Permissions & Privacy

- **100% On-Device & Private**: ClipStack makes zero external network requests. All image processing, OCR, and clipboard history storage happens locally on your Mac.
- **Accessibility Permission (for Auto-Paste)**:
  To allow ClipStack to simulate `⌘V` when you select an item, enable Accessibility in:  
  **System Settings → Privacy & Security → Accessibility → ClipStack**  
  *(If disabled, ClipStack will still copy the item and show a prompt to press `⌘V`).*
- **Launch at Login**:
  To have ClipStack start automatically when your Mac turns on:
  Right-click the menu bar icon (or click the ⚙️ gear icon) and verify **Launch at Login** is checked.

---

## 📁 Project Structure

```
smart-clipboard-mac/
├── Package.swift               # Swift Package Manager manifest
├── build.sh                    # Automated release build, codesign & install script
├── Resources/
│   ├── AppIcon.icns            # Retina macOS application icon
│   └── Info.plist              # Bundle metadata & usage descriptions
├── Sources/
│   └── ClipStack/
│       ├── main.swift          # Application entrypoint (NSApplication.shared)
│       ├── AppDelegate.swift   # Menu bar status item, hotkeys, login service
│       ├── ClipboardStore.swift# Pasteboard monitor, image persistence & export
│       ├── QueueManager.swift  # Sequential Paste (Queue Mode) FIFO manager
│       ├── HistoryPanel.swift  # Liquid Glass UI, Quick Look drawer, tabs & cards
│       ├── SmartText.swift     # URL, Color, JSON, Base64 & case transformers
│       ├── OCR.swift           # Apple Vision framework neural OCR engine
│       ├── HotKey.swift        # Carbon global hotkey wrapper
│       ├── ScreenshotWatcher.swift # Real-time screenshot directory watcher
│       ├── Utilities.swift     # Liquid glass view modifiers, HUD toasts & paster
│       └── Prefs.swift         # User preferences and keyboard presets
└── docs/
    └── assets/
        ├── banner.svg          # Hero graphic
        └── interface_preview.svg # High-res UI mockup
```

---

## 📄 License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.

---

<div align="center">
  <b>Crafted with ❤️ for macOS by <a href="https://github.com/batmandevx">batmandevx</a></b>
</div>
