import AppKit
import MeadowKit

// Usage: mdsnap <file.md> <out.png> [width] [theme] [revealOffset]
let args = CommandLine.arguments
let text = try! String(contentsOfFile: args[1], encoding: .utf8)
let width = args.count > 3 ? CGFloat(Double(args[3])!) : 760
let theme = args.count > 4 ? Theme.named(args[4]) : .moss
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let (scroll, tv) = MarkdownTextView.scrollable(style: EditorStyle(theme: theme))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = scroll
tv.baseURL = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
if ["json", "jsonc"].contains(URL(fileURLWithPath: args[1]).pathExtension.lowercased()) { tv.sourceLanguage = "json" }
let t0 = Date()
tv.setMarkdown(text)
if args.count > 5 {
    window.makeFirstResponder(tv)
    tv.setSelectedRange(NSRange(location: Int(args[5])!, length: 0))
}
tv.layoutManager!.ensureLayout(for: tv.textContainer!)
FileHandle.standardError.write("load+layout \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)) ms\n".data(using: .utf8)!)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
tv.layoutManager!.ensureLayout(for: tv.textContainer!)
let h = min(tv.frame.height, 4000)
tv.frame.size.height = h
let rect = NSRect(x: 0, y: 0, width: tv.bounds.width, height: h)
let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
tv.cacheDisplay(in: rect, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
if ProcessInfo.processInfo.environment["DUMP"] != nil {
    let lm = tv.layoutManager!
    let s = tv.string as NSString
    for ci in 0..<min(s.length, Int(ProcessInfo.processInfo.environment["DUMP"]!)!) {
        let gi = lm.glyphIndexForCharacter(at: ci)
        let r = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let l = lm.location(forGlyphAt: gi)
        let ps = tv.textStorage!.attribute(.paragraphStyle, at: ci, effectiveRange: nil) as! NSParagraphStyle
        print(ci, s.substring(with: NSRange(location: ci, length: 1)).debugDescription, "prop", lm.propertyForGlyph(at: gi).rawValue, "x", l.x, "lineY", r.minY, "h", r.height, "fhi", ps.firstLineHeadIndent, "hi", ps.headIndent, "sb", ps.paragraphSpacingBefore, "lhm", ps.lineHeightMultiple)
    }
}
