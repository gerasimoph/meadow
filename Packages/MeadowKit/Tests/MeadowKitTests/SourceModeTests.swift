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

    func testSameTextAsMarkdownStillRendersMarkdown() {
        let (styler, _) = styled("# Title\n\n**bold**\n", language: nil)
        XCTAssertFalse(styler.analysis.spans.isEmpty)
    }
}
