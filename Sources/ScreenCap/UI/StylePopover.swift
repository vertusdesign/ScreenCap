import AppKit

/// Small colour cell in the palette grid.
private final class ColorCell: NSButton {
    let color: NSColor
    var isSelectedColor = false { didSet { needsDisplay = true } }

    init(color: NSColor, side: CGFloat = 20) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        title = ""
        toolTip = color.hexString
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let swatch = bounds.insetBy(dx: 2, dy: 2)
        color.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4).fill()

        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        ring.lineWidth = isSelectedColor ? 2 : 1
        (isSelectedColor ? NSColor.white : NSColor.white.withAlphaComponent(0.25)).setStroke()
        ring.stroke()
    }
}

/// Colour, thickness and per-tool options, shown from the tool strip.
///
/// The panel has a fixed content width: rows appear and disappear as the tool
/// changes, and letting the width float meant every such change reflowed the whole
/// panel and left it looking broken.
final class StylePopover: OverlayPanel {

    /// Emits the complete style after any edit — one channel instead of a
    /// callback per control, so the overlay never holds a half-updated style.
    var onStyleChange: ((ToolStyle) -> Void)?
    /// Fired when rows appear or disappear and the frame must be recomputed.
    var onContentChanged: (() -> Void)?
    var onEyedropperToggled: ((Bool) -> Void)?

    private static let contentWidth: CGFloat = 208

    private static let palette: [NSColor] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7", "#007AFF", "#5856D6", "#AF52DE",
        "#FF2D55", "#8E5A3C", "#FFFFFF", "#C7C7CC", "#8E8E93", "#48484A", "#1C1C1E", "#000000", "#F2F2F7"
    ].compactMap { NSColor(hex: $0) }

    private var style: ToolStyle
    private var tool: ToolKind

    private var paletteCells: [ColorCell] = []
    private var recentCells: [ColorCell] = []

    private let hexField = NSTextField(string: "")
    private let eyedropperButton: OverlayButton
    private let recentRow = NSStackView()
    private let recentSection = NSStackView()

    private let widthRow = NSStackView()
    private let widthSlider = NSSlider()
    private let widthValue = NSTextField(labelWithString: "")

    private let fontRow = NSStackView()
    private let fontSlider = NSSlider()
    private let fontValue = NSTextField(labelWithString: "")

    private let backdropRow = NSStackView()
    private let backdropSegments = NSSegmentedControl()
    private let backdropSwatch = ColorSwatchButton(size: 22)

    private let obfuscationStyleRow = NSStackView()
    private let obfuscationStyleSegments = NSSegmentedControl()
    private let obfuscationShapeRow = NSStackView()
    private let obfuscationShapeSegments = NSSegmentedControl()
    private let brushRow = NSStackView()
    private let brushSlider = NSSlider()
    private let brushValue = NSTextField(labelWithString: "")
    private let intensityRow = NSStackView()
    private let intensitySlider = NSSlider()
    private let intensityValue = NSTextField(labelWithString: "")

    private let eraserRow = NSStackView()
    private let eraserSlider = NSSlider()
    private let eraserValue = NSTextField(labelWithString: "")

    private let optionsSeparator = NSView.overlaySeparator(vertical: false)

    private var eyedropperActive = false
    private var ownsColorPanel = false
    private var colorPanelTarget: ColorTarget = .stroke

    private enum ColorTarget { case stroke, backdrop }

    init(tool: ToolKind, style: ToolStyle) {
        self.tool = tool
        self.style = style
        eyedropperButton = OverlayButton(
            symbolName: "eyedropper",
            tooltip: L10n.t("style.eyedropper"),
            hint: L10n.t("style.eyedropper.hint"),
            size: 24
        )
        super.init()
        translatesAutoresizingMaskIntoConstraints = false
        build()
        configure(for: tool, style: style)
    }

    // MARK: - Building

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])

        root.addArrangedSubview(buildPalette())
        root.addArrangedSubview(buildRecents())
        root.addArrangedSubview(buildHexRow())
        root.addArrangedSubview(optionsSeparator)
        optionsSeparator.widthAnchor.constraint(
            equalToConstant: Self.contentWidth - 20
        ).isActive = true

        buildSlider(
            row: widthRow, slider: widthSlider, value: widthValue,
            title: L10n.t("style.thickness"), range: 1...24,
            action: #selector(widthChanged)
        )
        buildSlider(
            row: fontRow, slider: fontSlider, value: fontValue,
            title: L10n.t("style.fontSize"), range: 10...96,
            action: #selector(fontSizeChanged)
        )
        buildBackdropRow()
        buildObfuscationRows()
        buildSlider(
            row: eraserRow, slider: eraserSlider, value: eraserValue,
            title: L10n.t("style.eraserSize"), range: 8...80,
            action: #selector(eraserSizeChanged)
        )

        for row in [widthRow, fontRow, backdropRow, obfuscationStyleRow,
                    obfuscationShapeRow, brushRow, intensityRow, eraserRow] {
            root.addArrangedSubview(row)
        }
    }

    private func buildPalette() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 4
        for rowIndex in 0..<2 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4
            for columnIndex in 0..<9 {
                let index = rowIndex * 9 + columnIndex
                guard index < Self.palette.count else { break }
                let cell = ColorCell(color: Self.palette[index])
                cell.target = self
                cell.action = #selector(paletteCellTapped(_:))
                paletteCells.append(cell)
                row.addArrangedSubview(cell)
            }
            grid.addArrangedSubview(row)
        }
        return grid
    }

    private func buildRecents() -> NSView {
        recentSection.orientation = .horizontal
        recentSection.spacing = 6
        recentSection.alignment = .centerY
        recentRow.orientation = .horizontal
        recentRow.spacing = 4
        recentSection.addArrangedSubview(label(L10n.t("style.recent")))
        recentSection.addArrangedSubview(recentRow)
        return recentSection
    }

    private func buildHexRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        hexField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexField.isBezeled = true
        hexField.bezelStyle = .roundedBezel
        hexField.alignment = .center
        hexField.target = self
        hexField.action = #selector(hexCommitted)
        hexField.toolTip = L10n.t("style.hex")
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.widthAnchor.constraint(equalToConstant: 96).isActive = true

        eyedropperButton.target = self
        eyedropperButton.action = #selector(eyedropperTapped)

        let systemPicker = OverlayButton(
            symbolName: "paintpalette",
            tooltip: L10n.t("style.systemPalette"),
            size: 24
        )
        systemPicker.target = self
        systemPicker.action = #selector(systemPickerTapped)

        row.addArrangedSubview(hexField)
        row.addArrangedSubview(eyedropperButton)
        row.addArrangedSubview(systemPicker)
        return row
    }

    private func buildSlider(
        row: NSStackView,
        slider: NSSlider,
        value: NSTextField,
        title: String,
        range: ClosedRange<Double>,
        action: Selector
    ) {
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        styleLabel(value)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let caption = label(title)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(equalToConstant: 58).isActive = true
        caption.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(caption)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
    }

    private func buildBackdropRow() {
        backdropRow.orientation = .horizontal
        backdropRow.spacing = 6
        backdropRow.alignment = .centerY

        backdropSegments.segmentCount = TextBackdrop.allCases.count
        backdropSegments.trackingMode = .selectOne
        for (index, backdrop) in TextBackdrop.allCases.enumerated() {
            backdropSegments.setImage(
                NSImage(systemSymbolName: backdrop.symbolName, accessibilityDescription: backdrop.title),
                forSegment: index
            )
            backdropSegments.setWidth(31, forSegment: index)
            backdropSegments.setToolTip(backdrop.title, forSegment: index)
        }
        backdropSegments.target = self
        backdropSegments.action = #selector(backdropChanged)

        backdropSwatch.target = self
        backdropSwatch.action = #selector(backdropColorTapped)
        backdropSwatch.toolTip = L10n.t("style.backdropColor")

        backdropRow.addArrangedSubview(backdropSegments)
        backdropRow.addArrangedSubview(backdropSwatch)
    }

    private func buildObfuscationRows() {
        obfuscationStyleRow.orientation = .horizontal
        obfuscationStyleRow.spacing = 6
        obfuscationStyleRow.alignment = .centerY
        obfuscationStyleSegments.segmentCount = ObfuscationStyle.allCases.count
        for (index, item) in ObfuscationStyle.allCases.enumerated() {
            obfuscationStyleSegments.setLabel(item.title, forSegment: index)
            obfuscationStyleSegments.setWidth(93, forSegment: index)
            obfuscationStyleSegments.setToolTip(L10n.t("hint.control.alternate"), forSegment: index)
        }
        obfuscationStyleSegments.target = self
        obfuscationStyleSegments.action = #selector(obfuscationStyleChanged)
        obfuscationStyleRow.addArrangedSubview(obfuscationStyleSegments)

        obfuscationShapeRow.orientation = .horizontal
        obfuscationShapeRow.spacing = 6
        obfuscationShapeRow.alignment = .centerY
        obfuscationShapeSegments.segmentCount = ObfuscationShape.allCases.count
        for (index, item) in ObfuscationShape.allCases.enumerated() {
            obfuscationShapeSegments.setImage(
                NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title),
                forSegment: index
            )
            obfuscationShapeSegments.setWidth(62, forSegment: index)
            obfuscationShapeSegments.setToolTip(item.title, forSegment: index)
        }
        obfuscationShapeSegments.target = self
        obfuscationShapeSegments.action = #selector(obfuscationShapeChanged)
        obfuscationShapeRow.addArrangedSubview(obfuscationShapeSegments)

        buildSlider(
            row: brushRow, slider: brushSlider, value: brushValue,
            title: L10n.t("style.brushSize"),
            range: Double(ObfuscationSettings.brushRange.lowerBound)...Double(ObfuscationSettings.brushRange.upperBound),
            action: #selector(brushSizeChanged)
        )
        buildSlider(
            row: intensityRow, slider: intensitySlider, value: intensityValue,
            title: L10n.t("style.intensity"),
            range: Double(ObfuscationSettings.intensityRange.lowerBound)...Double(ObfuscationSettings.intensityRange.upperBound),
            action: #selector(intensityChanged)
        )
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        styleLabel(field)
        return field
    }

    private func styleLabel(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 11)
        field.textColor = NSColor.white.withAlphaComponent(0.75)
    }

    // MARK: - Configuration

    func configure(for tool: ToolKind, style: ToolStyle) {
        self.tool = tool
        self.style = style

        hexField.stringValue = style.color.hexString
        widthSlider.doubleValue = Double(style.lineWidth)
        widthValue.stringValue = "\(Int(style.lineWidth))"
        fontSlider.doubleValue = Double(style.fontSize)
        fontValue.stringValue = "\(Int(style.fontSize))"
        eraserSlider.doubleValue = Double(style.eraserRadius)
        eraserValue.stringValue = "\(Int(style.eraserRadius))"
        backdropSegments.selectedSegment = TextBackdrop.allCases.firstIndex(of: style.textBackdrop) ?? 0
        backdropSwatch.color = style.backdropColor
        obfuscationStyleSegments.selectedSegment =
            ObfuscationStyle.allCases.firstIndex(of: style.obfuscation.style) ?? 0
        obfuscationShapeSegments.selectedSegment =
            ObfuscationShape.allCases.firstIndex(of: style.obfuscation.shape) ?? 0
        brushSlider.doubleValue = Double(style.obfuscation.brushSize)
        brushValue.stringValue = "\(Int(style.obfuscation.brushSize))"
        intensitySlider.doubleValue = Double(style.obfuscation.intensity)
        intensityValue.stringValue = "\(Int(style.obfuscation.intensity))"

        applyRowVisibility()
        refreshSelection()
        reloadRecentColors()
        onContentChanged?()
    }

    private func applyRowVisibility() {
        widthRow.isHidden = !tool.supportsLineWidth
        fontRow.isHidden = tool != .text
        backdropRow.isHidden = tool != .text
        obfuscationStyleRow.isHidden = tool != .obfuscate
        obfuscationShapeRow.isHidden = tool != .obfuscate
        intensityRow.isHidden = tool != .obfuscate
        brushRow.isHidden = !(tool == .obfuscate && style.obfuscation.shape == .brush)
        eraserRow.isHidden = tool != .eraser

        let anyOption = [widthRow, fontRow, backdropRow, obfuscationStyleRow,
                         obfuscationShapeRow, brushRow, intensityRow, eraserRow]
            .contains { !$0.isHidden }
        optionsSeparator.isHidden = !anyOption
        backdropSwatch.isHidden = !style.textBackdrop.usesBackdropColor
    }

    private func refreshSelection() {
        for cell in paletteCells + recentCells {
            cell.isSelectedColor = cell.color.hexString == style.color.hexString
        }
    }

    private func reloadRecentColors() {
        recentCells.forEach { $0.removeFromSuperview() }
        recentCells.removeAll()

        let recents = Settings.shared.recentColors
        recentSection.isHidden = recents.isEmpty
        for color in recents.prefix(7) {
            let cell = ColorCell(color: color, side: 18)
            cell.target = self
            cell.action = #selector(paletteCellTapped(_:))
            cell.isSelectedColor = color.hexString == style.color.hexString
            recentCells.append(cell)
            recentRow.addArrangedSubview(cell)
        }
    }

    private func emit() {
        onStyleChange?(style)
    }

    private func applyColor(_ color: NSColor, to target: ColorTarget) {
        switch target {
        case .stroke:
            style.color = color
            hexField.stringValue = color.hexString
            refreshSelection()
            emit()
            // A brand-new colour lands in the recents row and makes the panel
            // taller, so the frame has to be recomputed.
            let hadRecents = !recentSection.isHidden
            reloadRecentColors()
            if hadRecents != !recentSection.isHidden || recentCells.count != Settings.shared.recentColors.count {
                onContentChanged?()
            } else {
                onContentChanged?()
            }
        case .backdrop:
            style.backdropColor = color
            backdropSwatch.color = color
            emit()
        }
    }

    /// Reflects an eyedropper sample taken on the overlay.
    func updateSampledColor(_ color: NSColor) {
        applyColor(color, to: .stroke)
    }

    func setEyedropperActive(_ active: Bool) {
        eyedropperActive = active
        eyedropperButton.isActive = active
    }

    // MARK: - Actions

    @objc private func paletteCellTapped(_ sender: ColorCell) {
        applyColor(sender.color, to: .stroke)
    }

    @objc private func hexCommitted() {
        guard let color = NSColor(hex: hexField.stringValue) else {
            hexField.stringValue = style.color.hexString
            return
        }
        applyColor(color, to: .stroke)
    }

    @objc private func eyedropperTapped() {
        // Second press cancels, so the crosshair is never a one-way trip.
        setEyedropperActive(!eyedropperActive)
        onEyedropperToggled?(eyedropperActive)
    }

    @objc private func backdropColorTapped() {
        openSystemColorPanel(for: .backdrop, initial: style.backdropColor)
    }

    @objc private func systemPickerTapped() {
        openSystemColorPanel(for: .stroke, initial: style.color)
    }

    private func openSystemColorPanel(for target: ColorTarget, initial: NSColor) {
        colorPanelTarget = target
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(systemColorChanged(_:)))
        panel.color = initial
        panel.isContinuous = true
        // The overlay sits at shielding level, so the panel has to be lifted above
        // it or the user would click a button and see nothing appear.
        panel.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 2)
        panel.hidesOnDeactivate = false
        panel.makeKeyAndOrderFront(nil)
        ownsColorPanel = true
    }

    @objc private func systemColorChanged(_ sender: NSColorPanel) {
        applyColor(sender.color.usingColorSpace(.sRGB) ?? sender.color, to: colorPanelTarget)
    }

    @objc private func widthChanged() {
        style.lineWidth = CGFloat(widthSlider.doubleValue.rounded())
        widthValue.stringValue = "\(Int(style.lineWidth))"
        emit()
    }

    @objc private func fontSizeChanged() {
        style.fontSize = CGFloat(fontSlider.doubleValue.rounded())
        fontValue.stringValue = "\(Int(style.fontSize))"
        emit()
    }

    @objc private func eraserSizeChanged() {
        style.eraserRadius = CGFloat(eraserSlider.doubleValue.rounded())
        eraserValue.stringValue = "\(Int(style.eraserRadius))"
        emit()
    }

    @objc private func backdropChanged() {
        let index = backdropSegments.selectedSegment
        guard index >= 0, index < TextBackdrop.allCases.count else { return }
        style.textBackdrop = TextBackdrop.allCases[index]
        backdropSwatch.isHidden = !style.textBackdrop.usesBackdropColor
        emit()
        onContentChanged?()
    }

    @objc private func obfuscationStyleChanged() {
        let index = obfuscationStyleSegments.selectedSegment
        guard index >= 0, index < ObfuscationStyle.allCases.count else { return }
        style.obfuscation.style = ObfuscationStyle.allCases[index]
        emit()
    }

    @objc private func obfuscationShapeChanged() {
        let index = obfuscationShapeSegments.selectedSegment
        guard index >= 0, index < ObfuscationShape.allCases.count else { return }
        style.obfuscation.shape = ObfuscationShape.allCases[index]
        brushRow.isHidden = style.obfuscation.shape != .brush
        emit()
        onContentChanged?()
    }

    @objc private func brushSizeChanged() {
        style.obfuscation.brushSize = CGFloat(brushSlider.doubleValue.rounded())
        brushValue.stringValue = "\(Int(style.obfuscation.brushSize))"
        emit()
    }

    @objc private func intensityChanged() {
        style.obfuscation.intensity = CGFloat(intensitySlider.doubleValue.rounded())
        intensityValue.stringValue = "\(Int(style.obfuscation.intensity))"
        emit()
    }

    func detachSystemColorPanel() {
        guard ownsColorPanel else { return }
        ownsColorPanel = false
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        panel.level = .floating
    }
}
