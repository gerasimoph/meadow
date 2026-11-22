import XCTest
@testable import MeadowKit

final class AnalyzerTests: XCTestCase {
    func testHeadingMarker() {
        let a = MarkdownAnalyzer.analyze("# Title\n")
        XCTAssertEqual(a.lines[0].kind, .heading)
        XCTAssertEqual(a.spans.first?.range, NSRange(location: 0, length: 2))
    }

    func testUnicodeOffsets() {
        let text = "Привет 👋 **жирный** и `код`\n"
        let a = MarkdownAnalyzer.analyze(text)
        let ns = text as NSString
        let strong = a.spans.first { if case .strong = $0.kind { return true }; return false }
        XCTAssertEqual(strong.map { ns.substring(with: $0.range) }, "жирный")
        let code = a.spans.first { if case .code = $0.kind { return true }; return false }
        XCTAssertEqual(code.map { ns.substring(with: $0.range) }, "код")
    }

    func testTaskAndQuote() {
        let text = "> - [x] done\n> - [ ] todo\n"
        let a = MarkdownAnalyzer.analyze(text)
        let boxes = a.spans.compactMap { s -> Bool? in if case .checkbox(let c) = s.kind { return c }; return nil }
        XCTAssertEqual(boxes, [true, false])
        XCTAssertEqual(a.lines[0].quoteDepth, 1)
    }

    func testUnclosedFence() {
        let a = MarkdownAnalyzer.analyze("```js\nlet a\n")
        XCTAssertEqual(a.lines[0].kind, .fence)
        XCTAssertEqual(a.lines[1].kind, .code)
        XCTAssertEqual(a.codeBlocks.first?.language, "js")
    }

    func testCRLF() {
        let a = MarkdownAnalyzer.analyze("# A\r\n**b**\r\n")
        XCTAssertEqual(a.lines.count, 3)
        XCTAssertEqual(a.lines[1].start, 5)
    }

    func testLinePrefix() {
        let p = LinePrefix.parse("  > 3. [ ] text")
        XCTAssertEqual(p.indent, "  ")
        XCTAssertEqual(p.quote, "> ")
        XCTAssertEqual(p.marker, "3.")
        XCTAssertEqual(p.task, "[ ] ")
        XCTAssertEqual(p.continuation(), "  > 4. [ ] ")
        XCTAssertFalse(LinePrefix.parse("-not a list").hasMarker)
    }
}

final class StylingTests: XCTestCase {
    private func attributesDump(_ ts: NSTextStorage) -> [String] {
        var out: [String] = []
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .mdGlyph, .mdCheckbox, .mdPipe, .mdCodeBlock,
                                              .mdQuote, .mdInlineCode, .mdLink, .strikethroughStyle]
        for i in 0..<ts.length {
            var parts: [String] = []
            for k in keys {
                if let v = ts.attribute(k, at: i, effectiveRange: nil) {
                    parts.append(k == .mdCodeBlock ? "code" : "\(k.rawValue)=\(v)")
                }
            }
            if let ps = ts.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle {
                parts.append("ps=\(ps.headIndent),\(ps.firstLineHeadIndent),\(ps.maximumLineHeight),\(ps.paragraphSpacingBefore)")
            }
            out.append(parts.joined(separator: "|"))
        }
        return out
    }

    func testIncrementalMatchesFull() {
        let base = """
        # Title

        Some **bold** text and `code`.
        - [ ] task one
        - item
        > quote

        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        let x = 1
        ```
        Setext
        ===
        """
        let fragments = ["```", "\n", "# ", "**", "|", "- [ ] ", "> ", "x", "`", "\n\n", "---\n", "===", "[a](b)"]
        var rng = SystemRandomNumberGenerator()
        for round in 0..<2000 {
            let tv = MarkdownTextView(style: EditorStyle())
            tv.setMarkdown(base)
            let ts = tv.textStorage!
            for _ in 0..<6 {
                let before = ts.string
                let loc = Int.random(in: 0...ts.length, using: &rng)
                let len = Bool.random(using: &rng) ? 0 : Int.random(in: 0...min(6, ts.length - loc), using: &rng)
                let frag = fragments.randomElement(using: &rng)!
                ts.replaceCharacters(in: NSRange(location: loc, length: len), with: frag)
                let incremental = attributesDump(ts)
                tv.restyleAll()
                let full = attributesDump(ts)
                if incremental != full {
                    let i = zip(incremental, full).enumerated().first { $0.element.0 != $0.element.1 }!.offset
                    XCTFail("round \(round): mismatch at \(i) after replacing \(NSRange(location: loc, length: len)) with \(frag.debugDescription) in:\n\(before)\n=== result:\n\(ts.string)\n--- incremental: \(incremental[i])\n--- full: \(full[i])")
                    return
                }
            }
        }
    }

    func testNewlineContinuesTask() {
        let tv = MarkdownTextView(style: EditorStyle())
        tv.setMarkdown("- [x] done")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- [x] done\n- [ ] ")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- [x] done\n")
    }

    func testToggleCheckbox() {
        let tv = MarkdownTextView(style: EditorStyle())
        tv.setMarkdown("- [ ] a")
        tv.toggleCheckbox(at: 2)
        XCTAssertEqual(tv.string, "- [x] a")
        tv.undoManager?.undo()
    }

    func testTabIndentsListItem() {
        let tv = MarkdownTextView(style: EditorStyle())
        tv.setMarkdown("- a\n- b")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertTab(nil)
        XCTAssertEqual(tv.string, "- a\n  - b")
        tv.insertBacktab(nil)
        XCTAssertEqual(tv.string, "- a\n- b")
    }
}
