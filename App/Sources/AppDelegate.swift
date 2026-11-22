import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [WindowController] = []
    private var settingsPanel: NSPanel?
    private var isTerminating = false
    private let settings = AppSettings.shared

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(openRecentDelegate: self)
        settings.startObservingAppearance()
        // Wait one turn so that files delivered by `application(_:open:)` at launch win over restoration.
        DispatchQueue.main.async { [self] in
            guard controllers.isEmpty else { return }
            restoreWindows()
        }
    }

    private func restoreWindows() {
        let urls = settings.openRoots.map { URL(fileURLWithPath: $0) }.filter { $0.isDirectory }
        if urls.isEmpty, let last = settings.lastFolder, URL(fileURLWithPath: last).isDirectory {
            open(URL(fileURLWithPath: last))
        } else if urls.isEmpty {
            addController(WindowController(root: nil))
        } else {
            urls.forEach { open($0, remember: false) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        controllers.forEach { $0.saveNow() }
        return .terminateNow
    }

    func applicationDidResignActive(_ notification: Notification) {
        controllers.forEach { $0.saveNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let last = settings.lastFolder, URL(fileURLWithPath: last).isDirectory {
                open(URL(fileURLWithPath: last))
            } else {
                addController(WindowController(root: nil))
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { open($0) }
    }

    // MARK: - Opening

    /// Opens a folder (as a window root) or a note (selected inside a window for its parent folder).
    func open(_ url: URL, remember: Bool = true) {
        let url = url.realPathURL
        if remember { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        let isFolder = url.isDirectory
        let rootURL = isFolder ? url : url.deletingLastPathComponent()
        let note = isFolder ? nil : url

        let controller: WindowController
        if let existing = controllers.first(where: { $0.contains(url) }) {
            controller = existing
            if let note { existing.start(selecting: note) }
        } else {
            controller = WindowController(root: rootURL)
            addController(controller)
            controller.start(selecting: note)
            controllers.filter { $0.root == nil }.forEach { $0.close() }
        }
        settings.lastFolder = controller.root?.path
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func addController(_ c: WindowController) {
        c.onClose = { [weak self] closed in self?.windowClosed(closed) }
        controllers.append(c)
        saveOpenRoots()
        c.showWindow(nil)
    }

    private func windowClosed(_ c: WindowController) {
        controllers.removeAll { $0 === c }
        if !isTerminating { saveOpenRoots() }
    }

    private func saveOpenRoots() {
        settings.openRoots = controllers.compactMap { $0.root?.path }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FileNode.noteExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { open($0) }
    }

    // MARK: - Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc private func clearRecents(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }

    // MARK: - Settings and view actions

    @objc func showSettings(_ sender: Any?) {
        if settingsPanel == nil {
            let panel = NSPanel(contentViewController: SettingsViewController())
            panel.styleMask = [.titled, .closable, .utilityWindow]
            panel.title = "Settings"
            panel.isFloatingPanel = false
            panel.isReleasedWhenClosed = false
            settingsPanel = panel
            panel.center()
        }
        settingsPanel?.makeKeyAndOrderFront(nil)
    }

    @objc func biggerFont(_ sender: Any?) { settings.changeFontSize(by: 1) }
    @objc func smallerFont(_ sender: Any?) { settings.changeFontSize(by: -1) }
    @objc func actualFontSize(_ sender: Any?) { settings.setFontSize(15) }
}
