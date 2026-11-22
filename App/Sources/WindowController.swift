import AppKit
import MeadowKit

private extension NSToolbarItem.Identifier {
    static let settings = NSToolbarItem.Identifier("settings")
}

/// One window per root folder (or an empty-state window when `root` is nil).
final class WindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let root: URL?
    var onClose: ((WindowController) -> Void)?

    private let settings = AppSettings.shared
    private var sidebar: SidebarViewController?
    private var editor: EditorViewController?
    private var emptyState: EmptyStateViewController?
    private var watcher: FolderWatcher?
    private var popover: NSPopover?
    private var observer: NSObjectProtocol?

    init(root: URL?) {
        self.root = root
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        window.delegate = self

        if let root {
            let sidebar = SidebarViewController(root: root)
            let editor = EditorViewController(style: settings.style)
            self.sidebar = sidebar
            self.editor = editor
            let split = NSSplitViewController()
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
            sidebarItem.minimumThickness = 180
            sidebarItem.maximumThickness = 400
            sidebarItem.canCollapse = true
            let editorItem = NSSplitViewItem(viewController: editor)
            split.addSplitViewItem(sidebarItem)
            split.addSplitViewItem(editorItem)
            split.splitView.autosaveName = "MeadowSplit"
            window.contentViewController = split
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.title = root.lastPathComponent
            wire(sidebar: sidebar, editor: editor)

            let toolbar = NSToolbar(identifier: "MeadowToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.setFrameAutosaveName("Meadow:" + root.path)
            watcher = FolderWatcher(url: root) { [weak self] paths in self?.folderChanged(paths) }
        } else {
            let empty = EmptyStateViewController()
            emptyState = empty
            window.contentViewController = empty
            window.setContentSize(NSSize(width: 640, height: 440))
            window.title = "Meadow"
            window.setFrameAutosaveName("Meadow:empty")
        }
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        applySettings()
        observer = NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func wire(sidebar: SidebarViewController, editor: EditorViewController) {
        sidebar.onOpenNote = { [weak self] url in self?.openNote(url) }
        sidebar.onWillModify = { [weak editor] in editor?.saveNow() }
        sidebar.onRenamed = { [weak self] old, new in
            self?.editor?.relocate(from: old, to: new)
            self?.updateTitle()
            self?.rememberNote()
        }
        sidebar.onTrashed = { [weak self] url in
            guard let self, let cur = self.editor?.currentURL,
                  cur.path == url.path || cur.path.hasPrefix(url.path + "/") else { return }
            self.editor?.clear()
            self.updateTitle()
            self.rememberNote()
        }
        sidebar.onShowSettings = { [weak self] view in self?.showSettings(from: view) }
        editor.onOpenLink = { url in (NSApp.delegate as? AppDelegate)?.open(url) }
    }

    /// Restores the previously open note (or the given one) once the window is on screen.
    func start(selecting note: URL?) {
        guard let root, let sidebar else { return }
        let target = note ?? settings.lastNote(in: root.path).map { URL(fileURLWithPath: $0) }
        if let target, FileManager.default.fileExists(atPath: target.path) { sidebar.select(url: target) }
    }

    func contains(_ url: URL) -> Bool {
        guard let root else { return false }
        return url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    func saveNow() { editor?.saveNow() }

    // MARK: - Notes

    private func openNote(_ url: URL) {
        editor?.open(url)
        updateTitle()
        rememberNote()
    }

    private func updateTitle() {
        guard let root else { return }
        window?.title = editor?.currentURL?.deletingPathExtension().lastPathComponent ?? root.lastPathComponent
    }

    private func rememberNote() {
        guard let root else { return }
        settings.setLastNote(editor?.currentURL?.path, in: root.path)
    }

    // MARK: - File system events

    private func folderChanged(_ paths: [String]) {
        var dirs = Set<String>()
        for p in paths {
            dirs.insert(p)
            dirs.insert((p as NSString).deletingLastPathComponent)
        }
        sidebar?.refresh(directories: dirs)
        guard let editor, editor.currentURL != nil else { return }
        if !editor.handleExternalChange() {
            updateTitle()
            rememberNote()
        }
    }

    // MARK: - Settings

    private func applySettings() {
        let style = settings.style
        let theme = style.theme
        window?.appearance = theme.appearance
        window?.backgroundColor = theme.background
        editor?.apply(style: style)
        sidebar?.apply(theme: theme)
        emptyState?.apply(theme: theme)
    }

    func showSettings(from view: NSView) {
        if let popover, popover.isShown { popover.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = SettingsViewController()
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        popover = p
    }

    @objc private func toolbarSettingsClicked(_ sender: NSButton) { showSettings(from: sender) }

    // MARK: - Menu actions

    @objc func newNote(_ sender: Any?) { sidebar?.newNote() }
    @objc func newFolder(_ sender: Any?) { sidebar?.newFolder() }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = editor?.currentURL ?? root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newNote(_:)), #selector(newFolder(_:)), #selector(showInFinder(_:)): return root != nil
        default: return true
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) { editor?.saveNow() }

    func windowWillClose(_ notification: Notification) {
        editor?.saveNow()
        watcher?.stop()
        watcher = nil
        popover?.close()
        onClose?(self)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .settings else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings")
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(toolbarSettingsClicked(_:)))
        button.bezelStyle = .texturedRounded
        item.view = button
        item.label = "Settings"
        item.toolTip = "Settings"
        return item
    }
}

/// Shown when no folder is open.
final class EmptyStateViewController: NSViewController {
    private let button = NSButton(title: "Open Folder…", target: nil, action: #selector(AppDelegate.openDocument(_:)))

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        apply(theme: AppSettings.shared.theme)
    }

    func apply(theme: Theme) {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = theme.background.cgColor
    }
}
