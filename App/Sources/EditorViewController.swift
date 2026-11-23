import AppKit
import MeadowKit

/// Hosts the Markdown editor for one note at a time and handles loading, autosave and external changes.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    private(set) var currentURL: URL?
    /// Called when a file link should be opened inside the app.
    var onOpenLink: ((URL) -> Void)?

    private let scrollView: NSScrollView
    private let textView: MarkdownTextView
    private let emptyLabel = NSTextField(labelWithString: "No note selected")
    private var lastText = ""
    private var encoding = String.Encoding.utf8
    private var dirty = false
    private var isLoading = false
    private var saveWork: DispatchWorkItem?

    init(style: EditorStyle) {
        (scrollView, textView) = MarkdownTextView.scrollable(style: style)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 14)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        view = root
        textView.delegate = self
        textView.openLink = { [weak self] url in
            if url.isFileURL, FileNode.noteExtensions.contains(url.pathExtension.lowercased()) || url.isDirectory {
                self?.onOpenLink?(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        showEmptyState(true)
    }

    func apply(style: EditorStyle) {
        textView.style = style
        view.layer?.backgroundColor = style.theme.background.cgColor
        emptyLabel.textColor = style.theme.secondary
    }

    func focus() { view.window?.makeFirstResponder(textView) }

    private func showEmptyState(_ empty: Bool) {
        scrollView.isHidden = empty
        emptyLabel.isHidden = !empty
    }

    // MARK: - Loading

    private static func read(_ url: URL) -> (String, String.Encoding)? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return (s, .utf8) }
        var enc = String.Encoding.utf8
        guard let s = try? String(contentsOf: url, usedEncoding: &enc) else { return nil }
        return (s, enc)
    }

    /// Opens a note, saving the current one first. Opening the already-open note is a no-op.
    func open(_ url: URL) {
        if url == currentURL { return }
        saveNow()
        guard let (text, enc) = Self.read(url) else {
            NSSound.beep()
            clear()
            return
        }
        let language = FileNode.sourceLanguage(for: url)
        if textView.sourceLanguage != language {
            // Empty the view first so switching modes doesn't restyle the previous note.
            load("")
            textView.sourceLanguage = language
        }
        currentURL = url
        encoding = enc
        load(text)
        textView.baseURL = url.deletingLastPathComponent()
        showEmptyState(false)
        view.window?.makeFirstResponder(textView)
        scrollToTop()
    }

    private func load(_ text: String, selection: NSRange? = nil) {
        isLoading = true
        textView.setMarkdown(text, selection: selection)
        isLoading = false
        lastText = text
        dirty = false
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Empties the editor without saving (used when the note is gone).
    func clear() {
        saveWork?.cancel()
        currentURL = nil
        dirty = false
        lastText = ""
        textView.sourceLanguage = nil
        load("")
        textView.baseURL = nil
        showEmptyState(true)
    }

    /// Follows a rename/move of the open note (or of one of its ancestor folders).
    func relocate(from old: URL, to new: URL) {
        guard let cur = currentURL else { return }
        if cur.path == old.path {
            currentURL = new
        } else if cur.path.hasPrefix(old.path + "/") {
            currentURL = URL(fileURLWithPath: new.path + cur.path.dropFirst(old.path.count))
        }
        textView.baseURL = currentURL?.deletingLastPathComponent()
        // Renaming notes.md to data.json (or back) switches between Markdown and source view.
        if let url = currentURL { textView.sourceLanguage = FileNode.sourceLanguage(for: url) }
    }

    // MARK: - Saving

    func textDidChange(_ notification: Notification) {
        guard !isLoading, currentURL != nil else { return }
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty, let url = currentURL else { return }
        let text = textView.string
        guard text != lastText else { dirty = false; return }
        // Never overwrite changes made by another app since we last loaded or saved:
        // keep them in a sibling copy before writing ours.
        if let (disk, _) = Self.read(url), disk != lastText, disk != text {
            preserveExternalVersion(disk, of: url)
        }
        do {
            try text.write(to: url, atomically: true, encoding: encoding)
        } catch {
            do { try text.write(to: url, atomically: true, encoding: .utf8); encoding = .utf8 }
            catch { NSSound.beep(); return }
        }
        lastText = text
        dirty = false
    }

    private func preserveExternalVersion(_ text: String, of url: URL) {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        var copy: URL
        repeat {
            let suffix = n == 1 ? " (external changes)" : " (external changes \(n))"
            copy = folder.appendingPathComponent(base + suffix).appendingPathExtension(ext)
            n += 1
        } while FileManager.default.fileExists(atPath: copy.path)
        try? text.write(to: copy, atomically: true, encoding: .utf8)
    }

    // MARK: - External changes

    /// Called after file system events. Returns false if the open note no longer exists.
    @discardableResult
    func handleExternalChange() -> Bool {
        guard let url = currentURL else { return true }
        guard FileManager.default.fileExists(atPath: url.path) else {
            clear()
            return false
        }
        guard !dirty, let (text, enc) = Self.read(url), text != lastText else { return true }
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        encoding = enc
        load(text)
        let length = (text as NSString).length
        let loc = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: loc, length: min(selection.length, length - loc)))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }
}
