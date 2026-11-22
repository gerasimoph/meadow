import Foundation

public struct CodeToken {
    public enum Kind { case keyword, string, comment, number, type, function }
    /// Range relative to the code string passed in (UTF-16).
    public var range: NSRange
    public var kind: Kind
    public init(range: NSRange, kind: Kind) { self.range = range; self.kind = kind }
}

/// Lightweight, regex-free syntax highlighter for fenced code blocks.
public enum SyntaxHighlighter {
    public static func tokens(in code: String, language: String) -> [CodeToken] {
        []
    }
}
