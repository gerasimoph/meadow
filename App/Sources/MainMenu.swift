import AppKit
import MeadowKit

/// Builds the programmatic main menu.
enum MainMenu {
    static func build(openRecentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // App
        let app = submenu(main, appName)
        add(app, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        app.addItem(.separator())
        add(app, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")

        // File
        let file = submenu(main, "File")
        add(file, "New Note", #selector(WindowController.newNote(_:)), "n")
        add(file, "New Folder", #selector(WindowController.newFolder(_:)), "n", [.command, .shift])
        add(file, "Open…", #selector(AppDelegate.openDocument(_:)), "o")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = openRecentDelegate
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Show in Finder", #selector(WindowController.showInFinder(_:)), "r", [.command, .option])

        // Edit
        let edit = submenu(main, "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(edit, "Delete", #selector(NSText.delete(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        let action = #selector(NSTextView.performFindPanelAction(_:))
        add(find, "Find…", action, "f").tag = NSTextFinder.Action.showFindInterface.rawValue
        add(find, "Find Next", action, "g").tag = NSTextFinder.Action.nextMatch.rawValue
        add(find, "Find Previous", action, "g", [.command, .shift]).tag = NSTextFinder.Action.previousMatch.rawValue

        // Format
        let format = submenu(main, "Format")
        add(format, "Bold", #selector(MarkdownTextView.toggleBold(_:)), "b")
        add(format, "Italic", #selector(MarkdownTextView.toggleItalic(_:)), "i")
        add(format, "Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
        add(format, "Inline Code", #selector(MarkdownTextView.toggleInlineCode(_:)), "c", [.command, .option])
        add(format, "Link", #selector(MarkdownTextView.insertLink(_:)), "k")
        format.addItem(.separator())
        for level in 1...3 {
            add(format, "Heading \(level)", #selector(MarkdownTextView.setHeadingLevel(_:)), "\(level)", [.command, .option]).tag = level
        }
        format.addItem(.separator())
        add(format, "Toggle Task", #selector(MarkdownTextView.toggleTask(_:)), "l")

        // View
        let view = submenu(main, "View")
        add(view, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        view.addItem(.separator())
        add(view, "Bigger", #selector(AppDelegate.biggerFont(_:)), "=")
        let alt = add(view, "Bigger", #selector(AppDelegate.biggerFont(_:)), "+", [.command, .shift])
        alt.isAlternate = true
        add(view, "Smaller", #selector(AppDelegate.smallerFont(_:)), "-")
        add(view, "Actual Size", #selector(AppDelegate.actualFontSize(_:)), "0")
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Window
        let window = submenu(main, "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                            _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return item
    }
}
