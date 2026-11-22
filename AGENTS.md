# Meadow — notes for agents

Native macOS Markdown notes editor (Swift 5, AppKit, TextKit 1, no SwiftUI/WebView).
Project status and next steps live in the GitHub issues (pinned "📌 Статус проекта и что дальше").
Issues are written in Russian.

## Commands
- Generate project: `xcodegen generate` (the `.xcodeproj` is not committed).
- Build: `xcodebuild -project Meadow.xcodeproj -scheme Meadow -configuration Debug -derivedDataPath build/DerivedData build`
- Engine tests: `cd Packages/MeadowKit && swift test` (includes a fuzz test comparing incremental vs full styling).
- Render a file to PNG without the app: `cd Packages/MeadowKit && swift run mdsnap <file.md> <out.png> [width] [theme] [caretOffset]`.
- Install: `./scripts/install.sh` (Release build into /Applications).

## Architecture rules
- The text storage always holds the raw Markdown. Rendering is attributes + glyph tricks only; never insert or
  replace characters for display.
- Glyph-level effects go through the `.mdGlyph` attribute and `MarkdownLayoutManager`. A hidden character at a
  line start must stay a zero-width control glyph (a null glyph there breaks indents and drawing).
- Do not change attributes while `NSTextStorage` is processing an edit outside `didProcessEditing`
  (glyphs are not regenerated); defer instead (see `updateReveal`).
- cmark positions are not fully reliable (setext headings, tables after paragraphs, code blocks in list items):
  verify marker characters in the text before trusting a position.
- Any change to `MarkdownAnalysis`/`MarkdownStyler`/`MarkdownTextView` must keep `testIncrementalMatchesFull` green.
