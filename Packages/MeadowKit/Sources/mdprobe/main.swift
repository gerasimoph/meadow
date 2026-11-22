import Foundation
import MeadowKit
let path = CommandLine.arguments[1]; if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "raw" { CMarkDebug.dump(try! String(contentsOfFile: path, encoding: .utf8)); exit(0) }
let text = try! String(contentsOfFile: path, encoding: .utf8)
let ns = text as NSString
let t0 = Date()
let a = MarkdownAnalyzer.analyze(text)
let dt = Date().timeIntervalSince(t0)
if CommandLine.arguments.count > 2 { print("chars \(ns.length) lines \(a.lines.count) spans \(a.spans.count) time \(String(format: "%.2f", dt*1000)) ms"); exit(0) }
for (i, l) in a.lines.enumerated() {
    print("L\(i) \(l.kind) h\(l.headingLevel) q\(l.quoteDepth) leaf\(l.leaf) cs\(l.contentStart) blk\(l.block) mk\(l.markerKind) | \(ns.substring(with: l.range))")
}
for s in a.spans { print("  \(s.kind) leaf\(s.leaf) '\(ns.substring(with: s.range))'") }
print("top", a.topBlocks, "leaves", a.leafRanges.count)
