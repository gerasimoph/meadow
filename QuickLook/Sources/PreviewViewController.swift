import Cocoa
import MeadowKit
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var scrollView: NSScrollView!
    private var textView: MarkdownTextView!

    override func loadView() {
        let (scroll, tv) = MarkdownTextView.scrollable(style: EditorStyle(theme: .moss))
        tv.isPreview = true
        scrollView = scroll
        textView = tv
        view = scroll
        preferredContentSize = NSSize(width: 800, height: 900)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let text: String
        do {
            text = try Self.readText(at: url)
        } catch {
            handler(error)
            return
        }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        textView.style = EditorStyle(theme: dark ? .moss : .paper)
        textView.baseURL = url.deletingLastPathComponent()
        textView.setMarkdown(text)
        scrollToTop()
        handler(nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scrollToTop()
    }

    private func scrollToTop() {
        guard let scrollView else { return }
        let top = NSPoint(x: 0, y: -scrollView.contentInsets.top)
        scrollView.contentView.scroll(to: top)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func readText(at url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }
}
