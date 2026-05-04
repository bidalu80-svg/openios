# MarkdownView (Fork)

A powerful pure UIKit framework for rendering Markdown documents with real-time parsing and rendering capabilities. Battle tested in [FlowDown](https://github.com/Lakr233/FlowDown).

> **This is a fork of [Lakr233/MarkdownView](https://github.com/Lakr233/MarkdownView)** with enhancements for [Open UI](https://github.com/Ichigo3766/Open-UI), an iOS client for Open WebUI.

## Fork Changes

### 🔗 Clickable Links
- Links are now tappable out of the box — a default `linkHandler` opens URLs in Safari via `UIApplication.shared.open(url)`
- No additional configuration needed; works automatically in SwiftUI via `MarkdownView("text")`

### 🎨 HighlightSwift (Replaces Highlightr)
- Swapped [Highlightr](https://github.com/raspu/Highlightr) (Obj-C JSContext) → [HighlightSwift](https://github.com/appstefan/HighlightSwift) (pure Swift JavaScriptCore)
- **Lazy async per-block highlighting**: Code blocks render plain monospaced text immediately, then highlight asynchronously with a 300ms debounce — no color flickering during streaming
- **Dark mode**: `.dark(.github)` theme with automatic light/dark switching
- **LRU cache**: Highlighted results are cached to avoid re-highlighting on scroll

### 📐 Configurable Spacing
- Paragraph spacing, line spacing, heading spacing, blockquote spacing, and blockquote indent are now configurable via `theme.spacings` (previously hardcoded to 16/4)
- List spacing follows theme settings

### 📝 Improved List Rendering
- **Plain numbered lists**: Replaced circled emoji numbers (①②③) with plain `1.` `2.` `3.` CoreText rendering via `CTLineDraw`
- **Dynamic indent**: Measures max number width in a list and uses that + padding as the base indent — scales correctly for any list size
- **Left-aligned numbers**: Fixed position like bullet points for consistent alignment

### ✏️ Italic Emphasis
- Changed emphasis rendering from underline to italic font (matches standard markdown conventions)

### 🔧 Code Block Height Fix
- Code blocks use actual `intrinsicContentSize` instead of a formula-based height calculation — fixes extra bottom whitespace

### ⚡ Streaming Performance — Block-Level Incremental Rendering
Major rendering pipeline overhaul to keep 120Hz ProMotion smooth during long AI streaming sessions:

- **Block-level render cache** (`CachedBlockSegment`): Each `MarkdownBlockNode` is rendered once and cached. On every streaming update, only the blocks that actually changed are re-rendered — unchanged blocks (the entire clean prefix of the document) are reused at zero cost.
- **Persistent `NSMutableAttributedString` mutation**: Instead of rebuilding the full concatenated attributed string on every token (O(n_total)), the dirty tail is deleted and replaced in-place (O(n_dirty)). CoreText only re-lays out the portion that changed.
- **Deferred layout**: Removed the synchronous `layoutIfNeeded()` call after every streaming update. `setNeedsLayout()` is used instead, letting the run loop coalesce and batch layout passes — prevents main-thread stalls on large documents.
- **Throttled height measurement**: `boundingSize(for:)` / `intrinsicContentSize` (a full O(n) CoreText layout pass) is throttled to at most once per 150ms during streaming. Immediately measured when streaming ends or content changes.
- **`buildSingleBlock`**: New `TextBuilder.buildSingleBlock(node:view:viewProvider:)` method that renders a single `MarkdownBlockNode` in isolation, enabling the incremental path without a full document rebuild.

## Preview

![Preview](./Resources/Simulator%20Screenshot%20-%20iPad%20mini%20(A17%20Pro)%20-%202025-05-27%20at%2003.03.27.png)

## Features

- 🚀 **Real-time Rendering**: Live Markdown parsing and rendering as you type
- 🖥️ **Specialized for Mobile Display**: Optimized layout that extracts complex elements from lists for better readability
- 🎨 **Syntax Highlighting**: Beautiful code syntax highlighting with HighlightSwift
- 📊 **Math Rendering**: LaTeX math formula rendering with SwiftMath
- 📱 **Cross-Platform**: Native support for iOS, macOS, Mac Catalyst, and visionOS
- 🔗 **Clickable Links**: Links open in Safari automatically — no setup required

## Installation

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/Ichigo3766/MarkdownView", branch: "main"),
]
```

Platform compatibility:
- iOS 16.0+
- macOS 13.0+
- Mac Catalyst 16.0+
- visionOS 1.0+

## Usage

### SwiftUI

```swift
import MarkdownView

struct ContentView: View {
    var body: some View {
        MarkdownView("# Hello World\n\nLinks are [clickable](https://example.com) by default!")
    }
}
```

With custom theme:

```swift
MarkdownView("# Hello World", theme: .default)
```

### UIKit / AppKit

```swift
import MarkdownView
import MarkdownParser

let markdownTextView = MarkdownTextView()
let parser = MarkdownParser()
let result = parser.parse("# Hello World")
let content = MarkdownTextView.PreprocessedContent(parserResult: result, theme: .default)
markdownTextView.setMarkdown(content)

// Links are clickable by default, or set a custom handler:
markdownTextView.linkHandler = { payload, range, point in
    switch payload {
    case .url(let url): UIApplication.shared.open(url)
    case .string(let str): if let url = URL(string: str) { UIApplication.shared.open(url) }
    }
}
```

## Example

Check out the included example project to see MarkdownView in action:

```bash
cd Example
open Example.xcodeproj
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

### Acknowledgments

- Original framework by [Lakr233](https://github.com/Lakr233/MarkdownView)
- Code adapted from [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) by Guillermo Gonzalez, used under the MIT License.

---

Copyright 2025 © Lakr Aream. All rights reserved.
