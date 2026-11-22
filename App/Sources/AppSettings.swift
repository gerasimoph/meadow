import AppKit
import MeadowKit

/// UserDefaults-backed preferences. Every change posts `AppSettings.didChange`.
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("MeadowSettingsDidChange")
    static let autoTheme = "auto"

    struct FontChoice { let title: String; let name: String }

    static let fontSizeRange: ClosedRange<Double> = 12...24
    static let lineHeightRange: ClosedRange<Double> = 1.2...2.0
    static let widthRange: ClosedRange<Double> = 520...1000

    /// System Mono, a few built-ins, and any of the optional fonts that are installed.
    static let fontChoices: [FontChoice] = {
        var list = [FontChoice(title: "System Mono", name: ""),
                    FontChoice(title: "Menlo", name: "Menlo"),
                    FontChoice(title: "Courier New", name: "Courier New"),
                    FontChoice(title: "SF Pro", name: ".AppleSystemUIFont")]
        let optional: [(String, [String])] = [
            ("JetBrains Mono", ["JetBrainsMono-Regular", "JetBrains Mono"]),
            ("IBM Plex Mono", ["IBMPlexMono", "IBMPlexMono-Regular", "IBM Plex Mono"]),
            ("iA Writer Mono S", ["iAWriterMonoS-Regular", "iA Writer Mono S"]),
        ]
        for (title, names) in optional {
            if let n = names.first(where: { NSFont(name: $0, size: 12) != nil }) {
                list.append(FontChoice(title: title, name: n))
            }
        }
        return list
    }()

    private let defaults = UserDefaults.standard

    var themeID: String { didSet { store(themeID, "theme") } }
    var fontName: String { didSet { store(fontName, "fontName") } }
    var fontSize: Double { didSet { store(fontSize, "fontSize") } }
    var lineHeight: Double { didSet { store(lineHeight, "lineHeight") } }
    var maxWidth: Double { didSet { store(maxWidth, "maxWidth") } }

    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        let d = UserDefaults.standard
        themeID = d.string(forKey: "theme") ?? Theme.moss.id
        fontName = d.string(forKey: "fontName") ?? ""
        fontSize = d.object(forKey: "fontSize") as? Double ?? 15
        lineHeight = d.object(forKey: "lineHeight") as? Double ?? 1.5
        maxWidth = d.object(forKey: "maxWidth") as? Double ?? 680
    }

    /// Starts following the system appearance (needed for the Auto theme). Call once `NSApp` exists.
    func startObservingAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self, self.themeID == Self.autoTheme else { return }
            self.post()
        }
    }

    var theme: Theme {
        if themeID == Self.autoTheme {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? .moss : .paper
        }
        return Theme.named(themeID)
    }

    var style: EditorStyle {
        EditorStyle(theme: theme, fontName: fontName, fontSize: CGFloat(fontSize),
                    lineHeight: CGFloat(lineHeight), maxWidth: CGFloat(maxWidth))
    }

    func changeFontSize(by delta: Double) { setFontSize(fontSize + delta) }
    func setFontSize(_ v: Double) { fontSize = min(max(v, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound) }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    // MARK: - Session state

    var openRoots: [String] {
        get { defaults.stringArray(forKey: "openRoots") ?? [] }
        set { defaults.set(newValue, forKey: "openRoots") }
    }

    var lastFolder: String? {
        get { defaults.string(forKey: "lastFolder") }
        set { defaults.set(newValue, forKey: "lastFolder") }
    }

    func lastNote(in root: String) -> String? {
        (defaults.dictionary(forKey: "lastNotes") as? [String: String])?[root]
    }

    func setLastNote(_ note: String?, in root: String) {
        var d = (defaults.dictionary(forKey: "lastNotes") as? [String: String]) ?? [:]
        d[root] = note
        defaults.set(d, forKey: "lastNotes")
    }
}
