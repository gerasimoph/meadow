import AppKit
import XCTest
@testable import MeadowKit

final class TableLayoutTests: XCTestCase {
    private let narrow = "| A | B |\n|---|---|\n| one | two |\n"
    private let wide = """
    | Case | Input | Handling |
    |---|---|---|
    | Short | \(String(repeating: "long words here ", count: 12)) | n/a |
    | Next | x | y |

    """

    private func textView(_ text: String, width: CGFloat = 700) -> MarkdownTextView {
        let tv = MarkdownTextView(style: EditorStyle())
        tv.setFrameSize(NSSize(width: width, height: 600))
        tv.setMarkdown(text)
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        return tv
    }

    private func origin(of s: String, in tv: MarkdownTextView) -> NSPoint {
        let lm = tv.layoutManager!
        let gi = lm.glyphIndexForCharacter(at: (tv.string as NSString).range(of: s).location)
        let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        return NSPoint(x: frag.minX + lm.location(forGlyphAt: gi).x, y: frag.minY)
    }

    func testNarrowTableStaysAGrid() {
        let tv = textView(narrow)
        XCTAssertEqual(origin(of: "one", in: tv).y, origin(of: "two", in: tv).y)
        XCTAssertGreaterThan(origin(of: "two", in: tv).x, origin(of: "one", in: tv).x)
    }

    /// A table wider than the column becomes records: one line per cell, all cells at one indent,
    /// long cells wrapping in place instead of pushing later columns onto new lines.
    func testWideTableIsStacked() {
        let tv = textView(wide)
        let short = origin(of: "Short", in: tv)
        let long = origin(of: "long words", in: tv)
        let na = origin(of: "n/a", in: tv)
        XCTAssertEqual(short.x, long.x, accuracy: 0.5)
        XCTAssertEqual(long.x, na.x, accuracy: 0.5)
        XCTAssertGreaterThan(short.x, 0, "cells are indented past the column names")
        XCTAssertLessThan(short.y, long.y)
        XCTAssertLessThan(long.y, na.y)
        XCTAssertLessThan(na.y, origin(of: "Next", in: tv).y)

        var labels: [String] = []
        let ts = tv.textStorage!
        ts.enumerateAttribute(.mdCellLabel, in: NSRange(location: 0, length: ts.length)) { v, _, _ in
            if let l = v as? MDCellLabel { labels.append(l.text.string) }
        }
        XCTAssertEqual(labels, ["Case", "Input", "Handling", "Case", "Input", "Handling"])
    }

    /// The column is capped at `maxWidth`, so a narrow window is what turns a grid into records.
    func testNarrowingTheWindowStacksTheTable() {
        let tv = textView(narrow)
        tv.setFrameSize(NSSize(width: 120, height: 600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        XCTAssertLessThan(origin(of: "one", in: tv).y, origin(of: "two", in: tv).y)
        XCTAssertEqual(origin(of: "one", in: tv).x, origin(of: "two", in: tv).x, accuracy: 0.5)
    }

    /// Column names are drawn on the first line of each cell.
    func testLabelsSitOnTheirCellLines() {
        let tv = textView(wide)
        let lm = tv.layoutManager!
        let ts = tv.textStorage!
        var checked = 0
        ts.enumerateAttribute(.mdCellLabel, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            guard v != nil else { return }
            let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: r.location), effectiveRange: nil)
            let cellLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: r.location + 1), effectiveRange: nil)
            XCTAssertEqual(frag, cellLine)
            checked += 1
        }
        XCTAssertEqual(checked, 6)
    }
}
