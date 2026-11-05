# ClipStack 📋

A native macOS menu bar clipboard manager and productivity toolbox crafted with **Apple Liquid Glass UI/UX**, fluid spring physics, and on-device machine learning (Apple Vision OCR).

---

## ✨ Features & Liquid Glass UX

### 🔮 Apple Liquid Glass Design
- **Translucent Specular Glass**: Layered materials (`.hudWindow` / `.popover`) with refraction bevel borders and soft ambient glow.
- **Fluid Spring Animations**: Smooth physics-based hover transitions and interactive card elevation.
- **Sliding Liquid Segmented Control**: Sliding capsule pill with matched geometry physics across category tabs.
- **Mac Haptic Feedback**: Subtle mechanical haptics on selection, copying, and pinning.

---

### 🚀 Life-Convenience Power Features

1. **Smart Content Intelligence**:
   - **Color Detection**: Copied hex colors (e.g. `#6366F1`) or RGB values render a live glass color swatch with one-click hex copying.
   - **URL & Link Intelligence**: Automatically tags links, detects domains, and adds an **Open in Browser (`⌘O`)** shortcut.
   - **JSON Detection**: Detects structured JSON with a `{ } JSON` badge.

2. **Quick Look Glass Drawer (`Space`)**:
   - Press **`Space`** on any item to slide open a detailed preview drawer.
   - View full-length un-truncated text, word count, character count, and line statistics.
   - View high-res images and selectable OCR text.

3. **One-Click Transformations (Smart Formatting)**:
   - **Paste Plain Text (`⇧↩`)**: Strips rich-text styles, weird line endings, and whitespace.
   - **Case Converters**: One-click convert to `UPPERCASE`, `lowercase`, `Title Case`, `camelCase`, and `snake_case`.
   - **Beautify JSON**: Re-formats and indents minified JSON with clean syntax.

4. **OCR & Text Extraction**:
   - Background OCR indexes text inside copied photos and screenshots for instant search.
   - **`⌘E`**: Extract text from selected image.
   - **`⌘⇧2`**: Drag any region on screen to extract text.

5. **Category Filters**:
   - **All**, **Text**, **Images**, **Links**, and **Pinned**.

---

## ⌨️ Shortcuts Reference

| Shortcut | Action |
| :--- | :--- |
| **`⌘⇧V`** | Open Clipboard History |
| **`⌘⇧2`** | Interactive Screen Text Extractor (drag region & OCR) |
| **`Space`** | Toggle Quick Look preview drawer & text tools |
| **`↩ (Return)`** | Paste item into active app |
| **`⇧↩ (Shift+Return)`** | Paste as clean plain text |
| **`⌘1` … `⌘9`** | Instant-paste items 1 through 9 |
| **`⌘O`** | Open URL in default browser (if clip is a link) |
| **`⌘E`** | Extract text from image |
| **`⌘P`** | Pin / unpin item |
| **`⌘⌫`** | Delete item |
| **`Esc`** | Close Quick Look / clear search / dismiss |

---

## 🛠️ Build & Install

```bash
./build.sh install
```
Installed directly to `/Applications/ClipStack.app` and enabled at login.
