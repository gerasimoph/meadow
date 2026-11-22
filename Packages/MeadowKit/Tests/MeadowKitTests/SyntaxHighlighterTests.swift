import XCTest
@testable import MeadowKit

final class SyntaxHighlighterTests: XCTestCase {
    private func texts(_ code: String, _ lang: String) -> [(String, CodeToken.Kind)] {
        let ns = code as NSString
        return SyntaxHighlighter.tokens(in: code, language: lang).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func has(_ t: [(String, CodeToken.Kind)], _ s: String, _ k: CodeToken.Kind) -> Bool {
        t.contains { $0.0 == s && $0.1 == k }
    }

    func testSwift() {
        let code = "let x = \"hi // no\" // note\nfunc Foo() { bar(42) }"
        let t = texts(code, "swift")
        XCTAssertTrue(has(t, "let", .keyword))
        XCTAssertTrue(has(t, "\"hi // no\"", .string))
        XCTAssertTrue(has(t, "// note", .comment))
        XCTAssertTrue(has(t, "func", .keyword))
        XCTAssertTrue(has(t, "Foo", .type))
        XCTAssertTrue(has(t, "bar", .function))
        XCTAssertTrue(has(t, "42", .number))
        XCTAssertEqual(SyntaxHighlighter.tokens(in: code, language: "swift").first?.range, NSRange(location: 0, length: 3))
    }

    func testSwiftTripleQuoteAndBlockComment() {
        let t = texts("/* a\nb */ let s = \"\"\"\nx \"y\"\n\"\"\"", "Swift")
        XCTAssertTrue(has(t, "/* a\nb */", .comment))
        XCTAssertTrue(has(t, "\"\"\"\nx \"y\"\n\"\"\"", .string))
    }

    func testPython() {
        let t = texts("x = 0xFF  # hi\ndef f(a): return 'it'", "py")
        XCTAssertTrue(has(t, "# hi", .comment))
        XCTAssertTrue(has(t, "0xFF", .number))
        XCTAssertTrue(has(t, "def", .keyword))
        XCTAssertTrue(has(t, "f", .function))
        XCTAssertTrue(has(t, "'it'", .string))
    }

    func testUTF16Offsets() {
        let code = "// 😀\nlet a"
        let tokens = SyntaxHighlighter.tokens(in: code, language: "swift")
        XCTAssertEqual(tokens.last?.range, NSRange(location: 6, length: 3))
    }

    func testUnknownLanguage() {
        let t = texts("foo(1, \"two\") // three", "brainfuck")
        XCTAssertEqual(t.map { $0.1 }, [.function, .number, .string, .comment])
        XCTAssertTrue(SyntaxHighlighter.tokens(in: "# hi", language: "markdown").isEmpty)
    }

    func testDiffAndHTML() {
        let d = texts("+add\n-del\n ctx", "diff")
        XCTAssertEqual(d.map { $0.1 }, [.string, .keyword])
        let h = texts("<div class=\"a\"><!-- c --></div>", "html")
        XCTAssertTrue(has(h, "div", .keyword))
        XCTAssertTrue(has(h, "\"a\"", .string))
        XCTAssertTrue(has(h, "<!-- c -->", .comment))
    }
}
