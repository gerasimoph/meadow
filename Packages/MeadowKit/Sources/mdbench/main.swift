import AppKit
import MeadowKit

// Usage: mdbench <file.md>  — times document load phases and per-keystroke processing.
let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let (scroll, tv) = MarkdownTextView.scrollable(style: EditorStyle())
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = scroll
window.makeFirstResponder(tv)
func ms(_ t: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(t) * 1000) }

var t = Date()
_ = MarkdownAnalyzer.analyze(text)
print("parse", ms(t), "ms")
let bare = NSTextStorage(string: text)
t = Date()
_ = MarkdownAnalyzer.analyze(bare.string)
print("parse (from NSTextStorage string)", ms(t), "ms")
let styler = MarkdownStyler(style: EditorStyle())
styler.reparse(bare.string)
t = Date()
bare.beginEditing(); styler.apply(NSRange(location: 0, length: bare.length), to: bare); bare.endEditing()
print("style only (no layout manager)", ms(t), "ms")
if ProcessInfo.processInfo.environment["STYLE_ONLY"] != nil {
    for _ in 0..<4 { bare.beginEditing(); styler.apply(NSRange(location: 0, length: bare.length), to: bare); bare.endEditing() }
    exit(0)
}
t = Date()
tv.setMarkdown(text)
print("setMarkdown (parse+style)", ms(t), "ms")
t = Date()
tv.layoutManager!.ensureLayout(forBoundingRect: scroll.contentView.bounds, in: tv.textContainer!)
print("layout visible", ms(t), "ms")
t = Date()
scroll.display()
print("first draw", ms(t), "ms")

// Keystrokes: insert a character in the middle of a paragraph, measure processing + visible relayout.
var samples: [Double] = []
let ns = text as NSString
for i in 0..<300 {
    let loc = min(ns.length - 1, (ns.length / 300) * i + 7)
    tv.setSelectedRange(NSRange(location: loc, length: 0))
    let start = Date()
    tv.insertText("a", replacementRange: tv.selectedRange())
    tv.layoutManager!.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
    samples.append(Date().timeIntervalSince(start) * 1000)
}
samples.sort()
print(String(format: "keystroke median %.2f ms, p95 %.2f ms, max %.2f ms", samples[samples.count / 2], samples[samples.count * 95 / 100], samples.last!))
