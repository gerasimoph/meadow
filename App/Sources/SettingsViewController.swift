import AppKit
import MeadowKit

/// Theme, font and layout controls. Used in the popover and in the Settings panel.
final class SettingsViewController: NSViewController {
    private let settings = AppSettings.shared
    private let themePopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizeSlider = NSSlider()
    private let lineSlider = NSSlider()
    private let widthSlider = NSSlider()
    private let sizeValue = NSTextField(labelWithString: "")
    private let lineValue = NSTextField(labelWithString: "")
    private let widthValue = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func loadView() {
        themePopup.addItem(withTitle: "Auto")
        themePopup.lastItem?.representedObject = AppSettings.autoTheme
        for t in Theme.all {
            themePopup.addItem(withTitle: t.name)
            themePopup.lastItem?.representedObject = t.id
        }
        themePopup.target = self; themePopup.action = #selector(themeChanged)

        for f in AppSettings.fontChoices {
            fontPopup.addItem(withTitle: f.title)
            fontPopup.lastItem?.representedObject = f.name
        }
        fontPopup.target = self; fontPopup.action = #selector(fontChanged)

        configure(sizeSlider, AppSettings.fontSizeRange, #selector(sizeChanged))
        configure(lineSlider, AppSettings.lineHeightRange, #selector(lineChanged))
        configure(widthSlider, AppSettings.widthRange, #selector(widthChanged))
        sizeSlider.numberOfTickMarks = 0
        sizeSlider.allowsTickMarkValuesOnly = false

        let rows = [row("Theme", themePopup), row("Font", fontPopup),
                    row("Size", sizeSlider, sizeValue), row("Line height", lineSlider, lineValue),
                    row("Width", widthSlider, widthValue)]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { $0.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        // A plain container with explicit margins: a stack view's own edge insets get lost as a popover's root view.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        view = container

        sync()
        observer = NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
    }

    private func configure(_ s: NSSlider, _ range: ClosedRange<Double>, _ action: Selector) {
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        s.target = self
        s.action = action
        s.isContinuous = true
    }

    private func row(_ title: String, _ control: NSView, _ value: NSTextField? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        var views: [NSView] = [label, control]
        if let value {
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 36).isActive = true
            views.append(value)
        }
        let r = NSStackView(views: views)
        r.spacing = 8
        r.alignment = .centerY
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return r
    }

    private func sync() {
        if let i = themePopup.itemArray.firstIndex(where: { $0.representedObject as? String == settings.themeID }) {
            themePopup.selectItem(at: i)
        }
        if let i = fontPopup.itemArray.firstIndex(where: { $0.representedObject as? String == settings.fontName }) {
            fontPopup.selectItem(at: i)
        }
        if sizeSlider.doubleValue != settings.fontSize { sizeSlider.doubleValue = settings.fontSize }
        if lineSlider.doubleValue != settings.lineHeight { lineSlider.doubleValue = settings.lineHeight }
        if widthSlider.doubleValue != settings.maxWidth { widthSlider.doubleValue = settings.maxWidth }
        sizeValue.stringValue = String(format: "%.0f", settings.fontSize)
        lineValue.stringValue = String(format: "%.2f", settings.lineHeight)
        widthValue.stringValue = String(format: "%.0f", settings.maxWidth)
        // Sliders in the theme's accent instead of the system blue.
        for s in [sizeSlider, lineSlider, widthSlider] { s.trackFillColor = settings.theme.accent }
    }

    @objc private func themeChanged() {
        if let id = themePopup.selectedItem?.representedObject as? String { settings.themeID = id }
    }

    @objc private func fontChanged() {
        if let name = fontPopup.selectedItem?.representedObject as? String { settings.fontName = name }
    }

    @objc private func sizeChanged() { settings.setFontSize(sizeSlider.doubleValue.rounded()) }
    @objc private func lineChanged() { settings.lineHeight = (lineSlider.doubleValue * 20).rounded() / 20 }
    @objc private func widthChanged() { settings.maxWidth = (widthSlider.doubleValue / 10).rounded() * 10 }
}
