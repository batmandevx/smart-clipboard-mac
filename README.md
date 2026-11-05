# ClipStack 📋

A native macOS menu bar clipboard manager and toolbox that brings the best of **Windows Clipboard History (Win+V)** and **PowerToys Text Extractor / Snipping Tool OCR** to macOS.

---

## ✨ Features

- **Never Lose Copied Items**:
  Every time you copy something, it is saved into your history without overwriting your previous copies. By default, it keeps your last 20 items (configurable to 50, 100, or 200 in settings).
- **Images & Screenshot Detection**:
  - Copies of images (PNG, JPEG, WebP, etc.) from browsers, apps, or Preview are captured with full thumbnails.
  - Automatically detects new screenshots taken with macOS shortcuts (`⌘⇧3`, `⌘⇧4`, `⌘⇧5`) and adds them to your clipboard history.
- **On-Device Text Extraction (OCR)**:
  - Powered by Apple's native Vision framework — fast, completely private, and works 100% offline.
  - Automatically indexes text inside images so you can **search for images by the text written inside them**.
  - One-click or `⌘E` shortcut to extract text from any image into a clean plain-text clip.
- **Screen Text Extractor (`⌘⇧2`)**:
  - Drag-select any region on your screen (even non-copyable text in videos, web apps, images, or protected PDFs) to instantly OCR and copy the text.
- **Instant Search & Category Tabs**:
  - Instant fuzzy search across text, image OCR contents, and file names.
  - Quick filters: **All**, **Text**, **Images**, and **Pinned**.
- **Pin Important Snippets**:
  - Pin items (`⌘P`) so they never get pruned when the history limit is reached.
- **Smart Auto-Paste**:
  - Press `Enter` or `⌘1`–`⌘9` to automatically paste the item directly into your active app.

---

## ⌨️ Shortcuts Reference

| Shortcut | Action |
| :--- | :--- |
| **⌘⇧V** | Toggle Clipboard History popup (customizable in menu: `⌥V`, `⌃⌥V`, etc.) |
| **⌘⇧2** | Extract text from screen region (crosshair drag & OCR) |
| **↑ / ↓** | Navigate history items |
| **↩ (Return)** | Paste selected item into active app |
| **⌘1 … ⌘9** | Instant-paste item 1 through 9 |
| **⌘E** | Extract text from selected image |
| **⌘P** | Pin / unpin selected item |
| **⌘⌫** | Delete selected item |
| **Space** | Open selected image/file in Preview |
| **Esc** | Clear search field or dismiss popup |

---

## 🚀 How to Run & Install

### Quick Build & Run
Run the build script to compile and install into `/Applications`:
```bash
./build.sh install
```
Or build without installing:
```bash
./build.sh
open build/ClipStack.app
```

### Accessibility Permission (for Auto-Paste)
To allow ClipStack to automatically paste items into your active application when you press `Enter` or click an item, grant **Accessibility** permission when prompted (or open **System Settings → Privacy & Security → Accessibility** and toggle **ClipStack** on).  
*If permission is not granted, ClipStack will still copy the item to your clipboard and show a reminder to press `⌘V`.*
