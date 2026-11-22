import cmark_gfm
import cmark_gfm_extensions

/// Prints cmark's raw node tree with source positions (debugging aid).
public enum CMarkDebug {
    public static func dump(_ text: String) {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return }
        for ext in ["table", "strikethrough", "tasklist"] {
            if let e = cmark_find_syntax_extension(ext) { cmark_parser_attach_syntax_extension(parser, e) }
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { cmark_parser_feed(parser, $0, bytes.count) }
        }
        guard let root = cmark_parser_finish(parser) else { return }
        func walk(_ n: UnsafeMutablePointer<cmark_node>, _ d: Int) {
            let t = String(cString: cmark_node_get_type_string(n))
            print(String(repeating: "  ", count: d) + "\(t) \(cmark_node_get_start_line(n)):\(cmark_node_get_start_column(n))-\(cmark_node_get_end_line(n)):\(cmark_node_get_end_column(n))")
            var c = cmark_node_first_child(n)
            while let ch = c { walk(ch, d + 1); c = cmark_node_next(ch) }
        }
        walk(root, 0)
        cmark_node_free(root)
        cmark_parser_free(parser)
    }
}
