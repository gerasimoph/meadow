import AppKit
import XCTest
@testable import MeadowKit

final class SourceModeTests: XCTestCase {
    private let json = "{\n  \"# title\": \"**not bold** [x](y)\",\n  \"count\": 42,\n  \"ok\": true\n}\n"

    private func styled(_ text: String, language: String?) -> (MarkdownStyler, NSTextStorage) {
        let styler = MarkdownStyler(style: EditorStyle())
        styler.sourceLanguage = language
        let ts = NSTextStorage(string: text)
        styler.reparse(text)
        ts.beginEditing()
        styler.apply(NSRange(location: 0, length: ts.length), to: ts)
        ts.endEditing()
        return (styler, ts)
    }

    func testJSONIsNotParsedAsMarkdown() {
        let (styler, ts) = styled(json, language: "json")
        XCTAssertTrue(styler.analysis.spans.isEmpty)
        XCTAssertTrue(styler.analysis.lines.allSatisfy { $0.kind == .body && $0.leaf == -1 })
        var markdownAttributes = 0
        for key in [NSAttributedString.Key.mdGlyph, .mdLink, .mdCheckbox, .mdPrefix] {
            ts.enumerateAttribute(key, in: NSRange(location: 0, length: ts.length)) { v, _, _ in
                if v != nil { markdownAttributes += 1 }
            }
        }
        XCTAssertEqual(markdownAttributes, 0)
    }

    func testJSONIsHighlighted() {
        let (_, ts) = styled(json, language: "json")
        let syntax = EditorStyle().theme.syntax
        let ns = json as NSString
        func color(_ s: String) -> NSColor? {
            ts.attribute(.foregroundColor, at: ns.range(of: s).location, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color("42"), syntax.number)
        XCTAssertEqual(color("true"), syntax.keyword)
        XCTAssertNotEqual(color("\"count\""), EditorStyle().theme.text)
    }

    /// Editing restyles only the edited lines; the result must match styling the whole file anew.
    func testIncrementalEditsMatchFullRestyle() {
        let tv = MarkdownTextView(style: EditorStyle())
        tv.sourceLanguage = "json"
        tv.setMarkdown(json)
        let edits: [(Int, String)] = [(4, "\"new\": 1,\n  "), (30, "9"), (10, "\n"), (0, "[")]
        for (at, insert) in edits {
            tv.textStorage!.replaceCharacters(in: NSRange(location: min(at, tv.textStorage!.length), length: 0), with: insert)
        }
        let (_, fresh) = styled(tv.string, language: "json")
        let ts = tv.textStorage!
        for i in 0..<ts.length {
            XCTAssertEqual(ts.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor,
                           fresh.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor, "color at \(i)")
            XCTAssertEqual(ts.attribute(.font, at: i, effectiveRange: nil) as? NSFont,
                           fresh.attribute(.font, at: i, effectiveRange: nil) as? NSFont, "font at \(i)")
        }
    }

    func testSameTextAsMarkdownStillRendersMarkdown() {
        let (styler, _) = styled("# Title\n\n**bold**\n", language: nil)
        XCTAssertFalse(styler.analysis.spans.isEmpty)
    }
}
