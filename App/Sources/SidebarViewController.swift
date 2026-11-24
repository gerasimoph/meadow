import AppKit
import MeadowKit

private final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onTrash: (() -> Void)?
    /// Extra left inset for disclosure arrows and names, so the list lines up with the folder title.
    let inset: CGFloat = 16

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = super.frameOfOutlineCell(atRow: row)
        if !r.isEmpty { r.origin.x += inset }
        return r
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        r.origin.x += inset
        r.size.width = max(0, r.size.width - inset)
        return r
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36 where mods.isEmpty, 76 where mods.isEmpty: onReturn?()
        case 51 where mods == .command: onTrash?()
        default: super.keyDown(with: event)
        }
    }
}

private final class ThemedRowView: NSTableRowView {
    var selectionColor = NSColor.selectedContentBackgroundColor

    override var isEmphasized: Bool { get { false } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 11, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// "New note": a filled, rounded button in the bottom bar.
private final class PillButton: NSButton {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 22, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? fill.blended(withFraction: 0.15, of: .white) ?? fill : fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        super.draw(dirtyRect)
    }
}

private final class NoteCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Folder header, note list and bottom toolbar.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSMenuDelegate, NSTextFieldDelegate {
    let rootNode: FileNode
    var onOpenNote: ((URL) -> Void)?
    /// Called right before files are renamed or trashed so the editor can flush pending edits.
    var onWillModify: (() -> Void)?
    var onRenamed: ((URL, URL) -> Void)?
    var onTrashed: ((URL) -> Void)?
    var onToggleTheme: (() -> Void)?

    private let outline = SidebarOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var addButton: PillButton!
    private var themeButton: NSButton!
    private let separator = NSView()
    private var theme = Theme.moss
    private var suppressSelection = false
    private var renaming: FileNode?
    private var menuNode: FileNode?

    init(root: URL) {
        rootNode = FileNode(url: root, isFolder: true)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func loadView() {
        let background = BackgroundView()
        view = background
        background.wantsLayer = true

        titleLabel.stringValue = rootNode.url.lastPathComponent
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let newNote = iconButton("square.and.pencil", "New Note", #selector(newNoteButton))
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpacer, newNote])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.rowHeight = 29
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.dataSource = self
        outline.delegate = self
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        column.resizingMask = .autoresizingMask
        outline.onReturn = { [weak self] in
            if let node = self?.selectedNode { self?.beginRename(node) }
        }
        outline.onTrash = { [weak self] in
            if let node = self?.selectedNode { self?.trash(node) }
        }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton = PillButton(title: " New note", image: symbol("plus", 11), target: self, action: #selector(newNoteButton))
        addButton.imagePosition = .imageLeading
        addButton.imageHugsTitle = true
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 13)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        themeButton = iconButton("sun.max", "Light or dark theme", #selector(themeButtonClicked))
        let bottom = NSStackView(views: [addButton, spacer,
                                         iconButton("folder.badge.plus", "New Folder", #selector(newFolderButton)),
                                         iconButton("tray", "Open Folder…", #selector(openFolderButton)),
                                         themeButton])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.spacing = 14
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 16)
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, scroll, separator, bottom] { background.addSubview(v) }
        let guide = background.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 50),
        ])
        apply(theme: theme)
    }

    private func symbol(_ name: String, _ size: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? image
    }

    private func iconButton(_ name: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: symbol(name, 14), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        buttons.append(b)
        return b
    }

    func apply(theme: Theme) {
        self.theme = theme
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = theme.sidebar.cgColor
        outline.backgroundColor = theme.sidebar
        titleLabel.textColor = theme.text
        buttons.forEach { $0.contentTintColor = theme.secondary }
        separator.layer?.backgroundColor = theme.rule.cgColor
        addButton.fill = theme.selection.withAlphaComponent(0.6)
        addButton.contentTintColor = theme.text
        addButton.attributedTitle = NSAttributedString(
            string: " New note", attributes: [.foregroundColor: theme.text, .font: NSFont.systemFont(ofSize: 13)])
        themeButton.image = symbol(theme.isDark ? "sun.max" : "moon", 14)
        outline.enumerateAvailableRowViews { row, _ in (row as? ThemedRowView)?.selectionColor = theme.selection.withAlphaComponent(0.6) }
        outline.reloadData()
        refreshTextColors()
    }

    // MARK: - Selection

    var selectedNode: FileNode? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? FileNode : nil
    }

    /// Reveals and selects the node for a URL inside the root. Selecting a note opens it.
    func select(url: URL?, notify: Bool = true) {
        guard let url else { return }
        let rootPath = rootNode.url.path
        guard url.path.hasPrefix(rootPath + "/") else { return }
        var node = rootNode
        for comp in url.path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard let next = node.child(named: String(comp)) else { return }
            if next.isFolder && next.url.path != url.path { outline.expandItem(next) }
            node = next
        }
        select(node, notify: notify)
    }

    private func select(_ node: FileNode, notify: Bool) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        suppressSelection = !notify
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelection = false
        outline.scrollRowToVisible(row)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshTextColors()
        guard !suppressSelection, let node = selectedNode, !node.isFolder else { return }
        onOpenNote?(node.url)
    }

    private func refreshTextColors() {
        outline.enumerateAvailableRowViews { row, index in
            guard let cell = row.view(atColumn: 0) as? NSTableCellView else { return }
            style(cell.textField, node: outline.item(atRow: index) as? FileNode, selected: row.isSelected)
        }
    }

    /// Selected row: bright and medium weight. Folders are a little brighter than files.
    private func style(_ field: NSTextField?, node: FileNode?, selected: Bool) {
        guard let field else { return }
        let folder = theme.text.blended(withFraction: 0.5, of: theme.secondary) ?? theme.text
        field.textColor = selected ? theme.heading : (node?.isFolder == true ? folder : theme.secondary)
        field.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
    }

    // MARK: - Data source

    private func children(of item: Any?) -> [FileNode] { ((item as? FileNode) ?? rootNode).children }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isFolder ?? false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ThemedRowView()
        row.selectionColor = theme.selection.withAlphaComponent(0.6)
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NoteCellView ?? {
            let c = NoteCellView()
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = node.name
        let row = outlineView.row(forItem: node)
        style(cell.textField, node: node, selected: row >= 0 && outlineView.isRowSelected(row))
        return cell
    }

    // MARK: - Refresh after file system events

    /// Re-lists the given directories (only those already loaded) and keeps selection and expansion.
    func refresh(directories: Set<String>) {
        let selected = selectedNode?.url
        var changed = false
        for path in directories {
            guard let node = loadedFolder(at: path), node.reload() else { continue }
            reloadOutline(node)
            changed = true
        }
        if changed, let selected, renaming == nil {
            suppressSelection = true
            select(url: selected, notify: false)
            suppressSelection = false
            if selectedNode == nil { outline.deselectAll(nil) }
        }
    }

    /// `reloadItem(nil, …)` does not reliably reload the root level, so use `reloadData()` there.
    private func reloadOutline(_ node: FileNode) {
        if node === rootNode { outline.reloadData() } else { outline.reloadItem(node, reloadChildren: true) }
    }

    private func loadedFolder(at path: String) -> FileNode? {
        let rootPath = rootNode.url.path
        if path == rootPath { return rootNode }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        var node = rootNode
        for comp in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard node.isLoaded, let next = node.child(named: String(comp)), next.isFolder else { return nil }
            node = next
        }
        return node.isLoaded ? node : nil
    }

    // MARK: - Creating items

    @objc private func newNoteButton() { newItem(isFolder: false, near: selectedNode) }
    @objc private func newFolderButton() { newItem(isFolder: true, near: selectedNode) }
    @objc private func openFolderButton() { NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: self) }
    @objc private func themeButtonClicked() { onToggleTheme?() }

    func newNote() { newItem(isFolder: false, near: selectedNode) }
    func newFolder() { newItem(isFolder: true, near: selectedNode) }

    private func newItem(isFolder: Bool, near node: FileNode?) {
        let folder: FileNode = node.map { $0.isFolder ? $0 : ($0.parent ?? rootNode) } ?? rootNode
        let fm = FileManager.default
        let base = isFolder ? "New Folder" : "Untitled"
        let ext = isFolder ? "" : "md"
        var n = 1
        var url: URL
        repeat {
            let name = n == 1 ? base : "\(base) \(n)"
            url = folder.url.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        do {
            if isFolder { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
            else { try Data().write(to: url, options: .withoutOverwriting) }
        } catch { NSSound.beep(); return }

        if folder !== rootNode { outline.expandItem(folder) }
        folder.reload()
        reloadOutline(folder)
        guard let created = folder.child(named: url.lastPathComponent) else { return }
        select(created, notify: true)
        DispatchQueue.main.async { [weak self] in self?.beginRename(created) }
    }

    // MARK: - Rename

    private func beginRename(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renaming = node
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.stringValue = node.name
        field.textColor = theme.text
        view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let node = renaming else { return }
        renaming = nil
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        commitRename(node, to: field.stringValue)
        let row = outline.row(for: field)
        if row >= 0, let current = outline.item(atRow: row) as? FileNode { field.stringValue = current.name }
        view.window?.makeFirstResponder(outline)
    }

    private func commitRename(_ node: FileNode, to input: String) {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != node.name else { return }
        if !node.isFolder {
            let ext = node.url.pathExtension
            if !ext.isEmpty && !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
        }
        let old = node.url
        let new = old.deletingLastPathComponent().appendingPathComponent(name)
        let sameFile = old.path.lowercased() == new.path.lowercased()
        if !sameFile && FileManager.default.fileExists(atPath: new.path) { NSSound.beep(); return }
        onWillModify?()
        do { try FileManager.default.moveItem(at: old, to: new) } catch { NSSound.beep(); return }
        onRenamed?(old, new)
        let parent = node.parent ?? rootNode
        parent.reload()
        reloadOutline(parent)
        if let renamed = parent.child(named: name) { select(renamed, notify: false) }
    }

    // MARK: - Trash

    private func trash(_ node: FileNode) {
        onWillModify?()
        do { try FileManager.default.trashItem(at: node.url, resultingItemURL: nil) } catch { NSSound.beep(); return }
        onTrashed?(node.url)
        let parent = node.parent ?? rootNode
        parent.reload()
        reloadOutline(parent)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outline.clickedRow
        menuNode = row >= 0 ? outline.item(atRow: row) as? FileNode : nil
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        add("New Note", #selector(menuNewNote))
        add("New Folder", #selector(menuNewFolder))
        menu.addItem(.separator())
        if menuNode != nil {
            add("Rename", #selector(menuRename))
            add("Show in Finder", #selector(menuShowInFinder))
            menu.addItem(.separator())
            add("Move to Trash", #selector(menuTrash))
        }
    }

    @objc private func menuNewNote() { newItem(isFolder: false, near: menuNode) }
    @objc private func menuNewFolder() { newItem(isFolder: true, near: menuNode) }
    @objc private func menuRename() { if let n = menuNode { beginRename(n) } }
    @objc private func menuTrash() { if let n = menuNode { trash(n) } }
    @objc private func menuShowInFinder() {
        if let n = menuNode { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
    }
}

private final class BackgroundView: NSView {}
