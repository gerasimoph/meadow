import AppKit

/// Colors used by the editor and the sidebar.
public struct Theme: Equatable {
    public var id: String
    public var name: String
    public var isDark: Bool
    public var background: NSColor
    public var sidebar: NSColor
    public var text: NSColor
    public var secondary: NSColor
    public var heading: NSColor
    public var accent: NSColor
    public var codeBackground: NSColor
    public var codeText: NSColor
    public var rule: NSColor
    public var selection: NSColor
    public var syntax: SyntaxColors

    public struct SyntaxColors: Equatable {
        public var keyword: NSColor
        public var string: NSColor
        public var comment: NSColor
        public var number: NSColor
        public var type: NSColor
        public var function: NSColor
    }

    public var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
}

private func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

public extension Theme {
    static let moss = Theme(
        id: "moss", name: "Moss", isDark: true,
        background: hex(0x1F271C), sidebar: hex(0x283224), text: hex(0xE4E7DC), secondary: hex(0x8A9682),
        heading: hex(0xF2F4EC), accent: hex(0xA9D18E), codeBackground: hex(0x2A3426), codeText: hex(0xDDE3D2),
        rule: hex(0x3E4A38), selection: hex(0x4B5E40),
        syntax: .init(keyword: hex(0xD7A86E), string: hex(0xA9D18E), comment: hex(0x7A8672),
                      number: hex(0xE0C27A), type: hex(0x8EC5C0), function: hex(0xC8B6E2)))

    static let graphite = Theme(
        id: "graphite", name: "Graphite", isDark: true,
        background: hex(0x1C1D20), sidebar: hex(0x25262A), text: hex(0xE2E2E4), secondary: hex(0x8B8C92),
        heading: hex(0xF4F4F6), accent: hex(0x8AB4F8), codeBackground: hex(0x26272B), codeText: hex(0xDCDCE0),
        rule: hex(0x3A3B40), selection: hex(0x3D4B63),
        syntax: .init(keyword: hex(0xF28FAD), string: hex(0xA6DA95), comment: hex(0x6E7079),
                      number: hex(0xF5A97F), type: hex(0x7DC4E4), function: hex(0xC6A0F6)))

    static let paper = Theme(
        id: "paper", name: "Paper", isDark: false,
        background: hex(0xFBFAF6), sidebar: hex(0xF1EFE8), text: hex(0x2B2A26), secondary: hex(0x8E8B80),
        heading: hex(0x1A1916), accent: hex(0x2F6E4F), codeBackground: hex(0xF0EEE6), codeText: hex(0x34332E),
        rule: hex(0xDDD9CC), selection: hex(0xCFE3D2),
        syntax: .init(keyword: hex(0xA2471F), string: hex(0x2F6E4F), comment: hex(0x9A968A),
                      number: hex(0x8A5A00), type: hex(0x1F5F8B), function: hex(0x6B3FA0)))

    static let all: [Theme] = [.moss, .graphite, .paper]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? .moss }
}

/// Typography and layout settings shared by the editor and the Quick Look preview.
public struct EditorStyle: Equatable {
    public var theme: Theme
    /// PostScript or family name; empty means the system monospaced font.
    public var fontName: String
    public var fontSize: CGFloat
    public var lineHeight: CGFloat
    /// Maximum width of the text column, in points.
    public var maxWidth: CGFloat

    public init(theme: Theme = .moss, fontName: String = "", fontSize: CGFloat = 15,
                lineHeight: CGFloat = 1.5, maxWidth: CGFloat = 680) {
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.maxWidth = maxWidth
    }

    public var baseFont: NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    public var codeFont: NSFont {
        let base = baseFont
        if base.isFixedPitch { return base }
        return NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
    }
}
