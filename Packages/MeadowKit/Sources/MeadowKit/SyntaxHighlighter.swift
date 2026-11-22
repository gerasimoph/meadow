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
        let name = language.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
        let canonical = aliases[name] ?? name
        switch canonical {
        case "markdown": return []
        case "diff": return diffTokens(code)
        default:
            let rules = table[canonical] ?? Rules()
            var scanner = CodeScanner(code: Array(code.utf16), rules: rules)
            return scanner.run()
        }
    }

    // MARK: - Language table

    private static let aliases: [String: String] = [
        "py": "python", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript", "rs": "rust", "c++": "cpp", "cc": "cpp", "cxx": "cpp",
        "h": "cpp", "hpp": "cpp", "objective-c": "objc", "objectivec": "objc", "m": "objc", "kt": "kotlin",
        "rb": "ruby", "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell",
        "yml": "yaml", "xml": "html", "svg": "html", "scss": "css", "less": "css", "md": "markdown",
        "golang": "go", "patch": "diff", "jsonc": "json", "postgres": "sql", "postgresql": "sql",
        "mysql": "sql", "sqlite": "sql",
    ]

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let table: [String: Rules] = {
        var t: [String: Rules] = [:]
        func cLike(_ kw: String) -> Rules {
            var r = Rules()
            r.keywords = words(kw)
            r.lineComments = [Array("//".utf16)]
            r.blockOpen = Array("/*".utf16); r.blockClose = Array("*/".utf16)
            r.capsTypes = true
            return r
        }

        var swift = cLike("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator \
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch \
        continue default defer do else fallthrough for guard if in repeat return throw switch where while any as \
        await async false is nil self Self super throws true try actor some final lazy mutating nonmutating override \
        weak unowned convenience required indirect get set willSet didSet
        """)
        swift.triple = true; swift.atIdent = true
        t["swift"] = swift

        var python = Rules()
        python.keywords = words("""
        and as assert async await break class continue def del elif else except finally for from global if import in \
        is lambda nonlocal not or pass raise return try while with yield True False None self cls match case
        """)
        python.lineComments = [[35]]
        python.triple = true; python.capsTypes = true; python.atIdent = true
        t["python"] = python

        let jsKeywords = """
        async await break case catch class const continue debugger default delete do else export extends finally for \
        from function if import in instanceof let new of return static super switch this throw try typeof var void \
        while with yield true false null undefined get set
        """
        var js = cLike(jsKeywords)
        js.backtick = true
        t["javascript"] = js
        var ts = cLike(jsKeywords + """
         interface type enum implements namespace declare abstract readonly public private protected as is keyof \
        infer satisfies unknown never any number string boolean object symbol bigint
        """)
        ts.backtick = true
        t["typescript"] = ts

        var json = Rules()
        json.keywords = words("true false null")
        json.quotes = [34]; json.jsonKeys = true
        json.lineComments = [Array("//".utf16)]
        json.blockOpen = Array("/*".utf16); json.blockClose = Array("*/".utf16)
        t["json"] = json

        var go = cLike("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map \
        package range return select struct switch type var true false nil iota
        """)
        go.backtick = true
        t["go"] = go

        var rust = cLike("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod \
        move mut pub ref return self Self static struct super trait true type unsafe use where while union
        """)
        rust.rustChars = true; rust.bangMacros = true
        t["rust"] = rust

        var c = cLike("""
        auto break case char const continue default do double else enum extern float for goto if inline int long \
        register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while \
        _Bool bool true false NULL
        """)
        c.directives = true
        t["c"] = c
        var cpp = cLike("""
        alignas alignof and auto bool break case catch char class const constexpr const_cast continue decltype default \
        delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long \
        mutable namespace new noexcept not nullptr operator or override private protected public register \
        reinterpret_cast return short signed sizeof static static_assert static_cast struct switch template this \
        throw true try typedef typeid typename union unsigned using virtual void volatile while final NULL
        """)
        cpp.directives = true
        t["cpp"] = cpp
        var objc = cLike("""
        auto break case char const continue default do double else enum extern float for goto if inline int long \
        return short signed sizeof static struct switch typedef union unsigned void volatile while self super nil \
        Nil YES NO BOOL id SEL Class IMP true false NULL instancetype
        """)
        objc.directives = true; objc.atIdent = true
        t["objc"] = objc

        var java = cLike("""
        abstract assert boolean break byte case catch char class const continue default do double else enum extends \
        final finally float for goto if implements import instanceof int interface long native new package private \
        protected public return short static strictfp super switch synchronized this throw throws transient try void \
        volatile while true false null var record sealed permits yield
        """)
        java.triple = true; java.atIdent = true
        t["java"] = java
        var kotlin = cLike("""
        as break class continue do else false for fun if in interface is null object package return super this throw \
        true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get \
        import init param property receiver set setparam value where abstract actual annotation companion const \
        crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out \
        override private protected public reified sealed suspend tailrec vararg
        """)
        kotlin.triple = true; kotlin.atIdent = true
        t["kotlin"] = kotlin

        var ruby = Rules()
        ruby.keywords = words("""
        alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or \
        redo rescue retry return self super then true undef unless until when while yield require require_relative \
        attr_accessor attr_reader attr_writer puts print raise lambda proc include extend private public protected
        """)
        ruby.lineComments = [[35]]; ruby.capsTypes = true
        t["ruby"] = ruby

        var shell = Rules()
        shell.keywords = words("""
        if then else elif fi for while until do done case esac in function return exit export local readonly declare \
        unset set shift break continue source alias echo cd select time eval exec trap true false
        """)
        shell.lineComments = [[35]]; shell.backtick = true
        t["shell"] = shell

        var sql = Rules()
        sql.keywords = words("""
        select from where and or not null is in like between join inner outer left right full cross on as group by \
        order having limit offset insert into values update set delete create table alter drop index view database \
        primary key foreign references unique default check constraint distinct union all case when then else end \
        exists asc desc with begin commit rollback transaction true false count sum avg min max if using returning \
        int integer text varchar char boolean date timestamp serial
        """)
        sql.caseInsensitive = true
        sql.lineComments = [Array("--".utf16)]
        sql.blockOpen = Array("/*".utf16); sql.blockClose = Array("*/".utf16)
        sql.backtick = true
        t["sql"] = sql

        var yaml = Rules()
        yaml.keywords = words("true false null yes no on off True False Null")
        yaml.lineComments = [[35]]; yaml.keySep = 58; yaml.dashIdent = true
        t["yaml"] = yaml
        var toml = Rules()
        toml.keywords = words("true false")
        toml.lineComments = [[35]]; toml.keySep = 61; toml.dashIdent = true
        t["toml"] = toml

        var html = Rules()
        html.blockOpen = Array("<!--".utf16); html.blockClose = Array("-->".utf16)
        html.htmlTags = true; html.dashIdent = true
        t["html"] = html

        var css = Rules()
        css.keywords = words("important")
        css.blockOpen = Array("/*".utf16); css.blockClose = Array("*/".utf16)
        css.lineComments = [Array("//".utf16)]
        css.dashIdent = true; css.atIdent = true; css.cssColors = true
        t["css"] = css

        return t
    }()

    // MARK: - Diff

    private static func diffTokens(_ code: String) -> [CodeToken] {
        var out: [CodeToken] = []
        code.enumerateSubstrings(in: code.startIndex..., options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let ns = NSRange(range, in: code)
            guard ns.length > 0, let first = code[range].utf16.first else { return }
            let line = code[range]
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                out.append(CodeToken(range: ns, kind: .comment))
            } else if first == 43 {
                out.append(CodeToken(range: ns, kind: .string))
            } else if first == 45 {
                out.append(CodeToken(range: ns, kind: .keyword))
            } else if first == 64 {
                out.append(CodeToken(range: ns, kind: .type))
            }
        }
        return out
    }
}

// MARK: - Scanner

private struct Rules {
    var keywords: Set<String> = []
    var caseInsensitive = false
    var lineComments: [[UInt16]] = [Array("//".utf16)]
    var blockOpen: [UInt16] = Array("/*".utf16)
    var blockClose: [UInt16] = Array("*/".utf16)
    var quotes: [UInt16] = [34, 39]
    var backtick = false
    var triple = false
    var rustChars = false
    var bangMacros = false
    var capsTypes = false
    var atIdent = false
    var dashIdent = false
    var directives = false
    var htmlTags = false
    var cssColors = false
    var jsonKeys = false
    /// Character after a key (`:` for YAML, `=` for TOML) that marks the identifier as a key.
    var keySep: UInt16 = 0
}

private struct CodeScanner {
    let s: [UInt16]
    let r: Rules
    var out: [CodeToken] = []
    var inTag = false

    init(code: [UInt16], rules: Rules) { s = code; r = rules }

    private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127 }
    private func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || c == 95 || c == 36 }
    private func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    private func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }

    private func has(_ p: [UInt16], at i: Int) -> Bool {
        guard !p.isEmpty, i + p.count <= s.count else { return false }
        for k in 0..<p.count where s[i + k] != p[k] { return false }
        return true
    }

    private func find(_ p: [UInt16], from i: Int) -> Int? {
        var j = i
        while j + p.count <= s.count { if has(p, at: j) { return j }; j += 1 }
        return nil
    }

    private func lineEnd(from i: Int) -> Int {
        var j = i
        while j < s.count && s[j] != 10 { j += 1 }
        return j
    }

    private mutating func emit(_ a: Int, _ b: Int, _ k: CodeToken.Kind) {
        out.append(CodeToken(range: NSRange(location: a, length: b - a), kind: k))
    }

    /// Index of the next non-blank (space/tab) character at or after `i`.
    private func skipBlanks(_ i: Int) -> Int {
        var j = i
        while j < s.count && (s[j] == 32 || s[j] == 9) { j += 1 }
        return j
    }

    mutating func run() -> [CodeToken] {
        let n = s.count
        var i = 0
        outer: while i < n {
            let c = s[i]

            // Block comments.
            if has(r.blockOpen, at: i) {
                let end = find(r.blockClose, from: i + r.blockOpen.count).map { $0 + r.blockClose.count } ?? n
                emit(i, end, .comment); i = end; continue
            }
            // HTML: only tags matter outside of them.
            if r.htmlTags && !inTag {
                if c == 60, i + 1 < n, isLetter(s[i + 1]) || (s[i + 1] == 47 && i + 2 < n && isLetter(s[i + 2])) {
                    var j = i + (s[i + 1] == 47 ? 2 : 1)
                    let start = j
                    while j < n && (isIdent(s[j]) || s[j] == 45 || s[j] == 58) { j += 1 }
                    emit(start, j, .keyword)
                    inTag = true; i = j
                } else { i += 1 }
                continue
            }
            if r.htmlTags && c == 62 { inTag = false; i += 1; continue }
            // Line comments (`#` must not directly follow an identifier or `$`, as in `$#`).
            for lc in r.lineComments where has(lc, at: i) {
                if lc[0] == 35, i > 0, isIdent(s[i - 1]) { continue }
                let end = lineEnd(from: i)
                emit(i, end, .comment); i = end; continue outer
            }
            // Preprocessor directives (`#include`).
            if c == 35 && r.directives {
                var k = i - 1
                while k >= 0 && (s[k] == 32 || s[k] == 9) { k -= 1 }
                if k < 0 || s[k] == 10 {
                    var j = skipBlanks(i + 1)
                    while j < n && isIdent(s[j]) { j += 1 }
                    emit(i, j, .keyword); i = j; continue
                }
            }
            // CSS hex colors.
            if c == 35 && r.cssColors {
                var j = i + 1
                while j < n && isHex(s[j]) { j += 1 }
                if (3...8).contains(j - i - 1) { emit(i, j, .number); i = j; continue }
            }
            // Strings.
            if r.quotes.contains(c) || (r.backtick && c == 96) {
                if r.rustChars && c == 39 {
                    if i + 2 < n && s[i + 1] == 92 {
                        var j = i + 2
                        while j < n && j < i + 12 && s[j] != 39 { j += 1 }
                        if j < n && s[j] == 39 { emit(i, j + 1, .string); i = j + 1; continue }
                    } else if i + 2 < n && s[i + 2] == 39 {
                        emit(i, i + 3, .string); i += 3; continue
                    }
                    i += 1; continue // lifetime
                }
                var j = i + 1
                if r.triple && c != 96 && i + 2 < n && s[i + 1] == c && s[i + 2] == c {
                    j = i + 3
                    while j < n {
                        if s[j] == 92 { j += 2; continue }
                        if s[j] == c, j + 2 < n, s[j + 1] == c, s[j + 2] == c { j += 3; break }
                        j += 1
                    }
                } else {
                    while j < n {
                        let d = s[j]
                        if d == 92 { j += 2; continue }
                        if d == c { j += 1; break }
                        if d == 10 && c != 96 { break }
                        j += 1
                    }
                }
                j = min(j, n)
                var kind = CodeToken.Kind.string
                if r.jsonKeys {
                    let k = skipBlanks(j)
                    if k < n && s[k] == 58 { kind = .type }
                }
                emit(i, j, kind); i = j; continue
            }
            // Numbers.
            if isDigit(c) {
                var j = i + 1
                let isHexLit = c == 48 && j < n && (s[j] == 120 || s[j] == 88)
                while j < n {
                    let d = s[j]
                    if isIdent(d) && d != 36 { j += 1 }
                    else if d == 46, j + 1 < n, isDigit(s[j + 1]) { j += 1 }
                    else if (d == 43 || d == 45), !isHexLit, j + 1 < n, isDigit(s[j + 1]), s[j - 1] == 101 || s[j - 1] == 69 { j += 1 }
                    else { break }
                }
                emit(i, j, .number); i = j; continue
            }
            // Identifiers and keywords.
            let atStart = r.atIdent && c == 64 && i + 1 < n && isLetter(s[i + 1])
            if isIdentStart(c) || atStart {
                var j = i + 1
                while j < n {
                    if isIdent(s[j]) { j += 1 }
                    else if r.dashIdent, s[j] == 45, j + 1 < n, isLetter(s[j + 1]) { j += 1 }
                    else { break }
                }
                if atStart { emit(i, j, .keyword); i = j; continue }
                // Ruby-style predicate names such as `defined?`.
                if r.keywords.contains("defined?"), j < n, s[j] == 63 { j += 1 }
                let len = j - i
                if !r.keywords.isEmpty && len <= 16 {
                    var word = String(decoding: s[i..<j], as: UTF16.self)
                    if r.caseInsensitive { word = word.lowercased() }
                    if r.keywords.contains(word) { emit(i, j, .keyword); i = j; continue }
                }
                if r.keySep != 0 {
                    let k = skipBlanks(j)
                    if k < n && s[k] == r.keySep && (r.keySep == 61 || k + 1 >= n || s[k + 1] == 32 || s[k + 1] == 10 || s[k + 1] == 13) {
                        emit(i, j, .type); i = j; continue
                    }
                }
                if r.capsTypes && s[i] >= 65 && s[i] <= 90 && !isAllCaps(i, j) {
                    emit(i, j, .type); i = j; continue
                }
                if j < n && (s[j] == 40 || (r.bangMacros && s[j] == 33 && j + 1 < n && (s[j + 1] == 40 || s[j + 1] == 91 || s[j + 1] == 123))) {
                    emit(i, j, .function)
                }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    private func isAllCaps(_ a: Int, _ b: Int) -> Bool {
        if b - a < 2 { return false }
        for k in a..<b { let d = s[k]; if !((d >= 65 && d <= 90) || isDigit(d) || d == 95) { return false } }
        return true
    }
}
