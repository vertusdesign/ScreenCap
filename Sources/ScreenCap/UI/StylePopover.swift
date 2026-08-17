import AppKit

enum StyleColorTarget: Equatable {
    case stroke
    case backdrop
}

/// Small color cell in the palette grid.
private final class ColorCell: NSButton {
    let color: NSColor
    let colorTarget: StyleColorTarget
    var isSelectedColor = false { didSet { needsDisplay = true } }

    init(color: NSColor, target: StyleColorTarget, side: CGFloat = 20) {
        self.color = color
        self.colorTarget = target
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
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

/// Color, thickness and per-tool options, shown from the tool strip.
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
    var onEyedropperToggled: ((Bool, StyleColorTarget) -> Void)?

    /// 9 palette columns at `paletteCellSide` with `paletteSpacing` gaps, plus the
    /// root stack's own 10pt edge insets on each side — sized to fit exactly, so
    /// the palette grid gets the same margins as every other row instead of
    /// overflowing and squashing its edge cells.
    private static let paletteCellSide: CGFloat = 18
    private static let paletteSpacing: CGFloat = 4
    private static let captionWidth: CGFloat = 82
    private static let sliderWidth: CGFloat = 96
    private static let valueWidth: CGFloat = 22
    private static let rowSpacing: CGFloat = 6
    private static let paletteWidth: CGFloat =
        9 * paletteCellSide + 8 * paletteSpacing
    private static let sliderRowWidth: CGFloat =
        captionWidth + rowSpacing + sliderWidth + rowSpacing + valueWidth
    private static let contentWidth: CGFloat =
        max(paletteWidth, sliderRowWidth) + 20

    private static let palette: [NSColor] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7", "#007AFF", "#5856D6", "#AF52DE",
        "#FF2D55", "#8E5A3C", "#FFFFFF", "#C7C7CC", "#8E8E93", "#48484A", "#1C1C1E", "#000000", "#F2F2F7"
    ].compactMap { NSColor(hex: $0) }

    private var style: ToolStyle
    private var tool: ToolKind

    private var paletteCells: [ColorCell] = []
    private var recentCells: [ColorCell] = []
    private var backdropPaletteCells: [ColorCell] = []
    private var backdropRecentCells: [ColorCell] = []

    private let hexField = NSTextField(string: "")
    private let backdropHexField = NSTextField(string: "")
    private let eyedropperButton: OverlayButton
    private let backdropEyedropperButton: OverlayButton
    private let systemPicker: OverlayButton
    private let backdropSystemPicker: OverlayButton
    private let recentRow = NSStackView()
    private let recentSection = NSStackView()
    private let backdropRecentRow = NSStackView()
    private let backdropRecentSection = NSStackView()
    private let backdropColorSection = NSStackView()

    private let widthRow = NSStackView()
    private let widthSlider = NSSlider()
    private let widthValue = NSTextField(labelWithString: "")
    private var widthCaption: NSTextField?

    private let counterArrowWidthRow = NSStackView()
    private let counterArrowWidthSlider = NSSlider()
    private let counterArrowWidthValue = NSTextField(labelWithString: "")

    private let fontRow = NSStackView()
    private let fontSlider = NSSlider()
    private let fontValue = NSTextField(labelWithString: "")

    private let backdropRow = NSStackView()
    private let backdropSegments = TooltipSegmentedControl()

    /// Rectangle/ellipse: outline vs filled. The persisted twin of ⌃.
    private let shapeStyleRow = NSStackView()
    private let shapeStyleSegments = TooltipSegmentedControl()
    /// Arrow: one head vs two. Also the persisted twin of ⌃.
    private let arrowStyleRow = NSStackView()
    private let arrowStyleSegments = TooltipSegmentedControl()

    private let obfuscationStyleRow = NSStackView()
    private let obfuscationStyleSegments = TooltipSegmentedControl()
    private let obfuscationShapeRow = NSStackView()
    private let obfuscationShapeSegments = TooltipSegmentedControl()
    private let markerShapeRow = NSStackView()
    private let markerShapeSegments = TooltipSegmentedControl()
    private let brushRow = NSStackView()
    private let brushSlider = NSSlider()
    private let brushValue = NSTextField(labelWithString: "")
    private let intensityRow = NSStackView()
    private let intensitySlider = NSSlider()
    private let intensityValue = NSTextField(labelWithString: "")

    private let eraserModeRow = NSStackView()
    private let eraserModeSegments = TooltipSegmentedControl()
    /// Eraser gets the same brush/rectangle/ellipse choice as redaction when it
    /// is in pixel mode.
    private let eraserShapeRow = NSStackView()
    private let eraserShapeSegments = TooltipSegmentedControl()
    private let eraserRow = NSStackView()
    private let eraserSlider = NSSlider()
    private let eraserValue = NSTextField(labelWithString: "")

    private let optionsSeparator = NSView.overlaySeparator(vertical: false)

    private var eyedropperActive = false
    private var ownsColorPanel = false
    private var colorPanelTarget: StyleColorTarget = .stroke
    private var isSynchronizingColorPanel = false
    private var colorPanelCloseObserver: NSObjectProtocol?

    init(tool: ToolKind, style: ToolStyle) {
        self.tool = tool
        self.style = style
        eyedropperButton = OverlayButton(
            symbolName: "eyedropper",
            tooltip: L10n.t("style.eyedropper"),
            hint: L10n.t("style.eyedropper.hint"),
            size: 24
        )
        backdropEyedropperButton = OverlayButton(
            symbolName: "eyedropper",
            tooltip: L10n.t("style.eyedropper"),
            hint: L10n.t("style.eyedropper.hint"),
            size: 24
        )
        systemPicker = OverlayButton(
            symbolName: "paintpalette",
            tooltip: L10n.t("style.systemPalette"),
            size: 24
        )
        backdropSystemPicker = OverlayButton(
            symbolName: "paintpalette",
            tooltip: L10n.t("style.systemPalette"),
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

        root.addArrangedSubview(buildPalette(target: .stroke))
        root.addArrangedSubview(buildRecents(target: .stroke))
        root.addArrangedSubview(buildHexRow(target: .stroke))
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
            row: counterArrowWidthRow, slider: counterArrowWidthSlider,
            value: counterArrowWidthValue, title: L10n.t("style.arrowThickness"),
            range: 1...24, action: #selector(counterArrowWidthChanged)
        )
        buildSlider(
            row: fontRow, slider: fontSlider, value: fontValue,
            title: L10n.t("style.fontSize"), range: 10...96,
            action: #selector(fontSizeChanged)
        )
        buildBackdropRow()
        buildBackdropColorSection()
        buildShapeStyleRow()
        buildArrowStyleRow()
        buildMarkerShapeRow()
        buildObfuscationRows()
        buildEraserModeRow()
        buildEraserShapeRow()
        buildSlider(
            row: eraserRow, slider: eraserSlider, value: eraserValue,
            title: L10n.t("style.eraserSize"), range: 8...80,
            action: #selector(eraserSizeChanged)
        )

        // Selector rows (shape style, arrow heads, text backdrop) before the
        // slider rows they share a tool with — thickness/font size sliders
        // read as tuning an already-chosen mode, not the other way round.
        for row in [shapeStyleRow, arrowStyleRow, backdropRow, backdropColorSection,
                    widthRow, counterArrowWidthRow, fontRow,
                    markerShapeRow, obfuscationStyleRow, obfuscationShapeRow, brushRow, intensityRow,
                    eraserModeRow, eraserShapeRow, eraserRow] {
            root.addArrangedSubview(row)
        }
    }

    private func buildPalette(target: StyleColorTarget) -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = Self.paletteSpacing
        for rowIndex in 0..<2 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = Self.paletteSpacing
            for columnIndex in 0..<9 {
                let index = rowIndex * 9 + columnIndex
                guard index < Self.palette.count else { break }
                let cell = ColorCell(color: Self.palette[index], target: target, side: Self.paletteCellSide)
                cell.target = self
                cell.action = #selector(paletteCellTapped(_:))
                if target == .stroke {
                    paletteCells.append(cell)
                } else {
                    backdropPaletteCells.append(cell)
                }
                row.addArrangedSubview(cell)
            }
            grid.addArrangedSubview(row)
        }
        return grid
    }

    private func buildRecents(target: StyleColorTarget) -> NSView {
        let section = target == .stroke ? recentSection : backdropRecentSection
        let row = target == .stroke ? recentRow : backdropRecentRow
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 0
        row.orientation = .horizontal
        row.spacing = Self.paletteSpacing
        section.addArrangedSubview(row)
        return section
    }

    private func buildHexRow(target: StyleColorTarget) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Self.rowSpacing
        row.alignment = .centerY

        let field = target == .stroke ? hexField : backdropHexField
        let eyedropper = target == .stroke ? eyedropperButton : backdropEyedropperButton
        let systemPicker = target == .stroke ? self.systemPicker : backdropSystemPicker

        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .center
        field.target = self
        field.action = #selector(hexCommitted(_:))
        field.toolTip = L10n.t("style.hex")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true

        eyedropper.target = self
        eyedropper.action = #selector(eyedropperTapped(_:))

        systemPicker.target = self
        systemPicker.action = #selector(systemPickerTapped(_:))

        row.addArrangedSubview(field)
        row.addArrangedSubview(eyedropper)
        row.addArrangedSubview(systemPicker)
        return row
    }

    private func buildBackdropColorSection() {
        backdropColorSection.orientation = .vertical
        backdropColorSection.alignment = .leading
        backdropColorSection.spacing = 8
        backdropColorSection.addArrangedSubview(label(L10n.t("style.backdropColor")))
        backdropColorSection.addArrangedSubview(buildPalette(target: .backdrop))
        backdropColorSection.addArrangedSubview(buildRecents(target: .backdrop))
        backdropColorSection.addArrangedSubview(buildHexRow(target: .backdrop))
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
        slider.focusRingType = .none
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: Self.sliderWidth).isActive = true
        styleLabel(value)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: Self.valueWidth).isActive = true

        let caption = label(title)
        if row === widthRow { widthCaption = caption }
        caption.translatesAutoresizingMaskIntoConstraints = false
        // The counter has a second slider labelled “Arrow thickness”; the old
        // 58pt column was enough for “Thickness” but visibly truncated the new
        // setting.  82pt still fits the fixed content width beside the slider
        // and keeps the label readable in every tool state.
        caption.widthAnchor.constraint(equalToConstant: Self.captionWidth).isActive = true
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
        backdropSegments.focusRingType = .none
        // Explicit height: `NSSegmentedControl`'s own intrinsic height varies by
        // macOS version and doesn't reliably match the 24pt icon buttons sharing
        // its row, which is what read as "rows of uneven height, some clipped
        // against the panel's rounded corner."
        backdropSegments.translatesAutoresizingMaskIntoConstraints = false
        backdropSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for (index, backdrop) in TextBackdrop.allCases.enumerated() {
            backdropSegments.setImage(
                NSImage.freshSystemSymbol(backdrop.symbolName, accessibilityDescription: backdrop.title),
                forSegment: index
            )
            backdropSegments.setWidth(31, forSegment: index)
            backdropSegments.setToolTip(backdrop.title, forSegment: index)
        }
        backdropSegments.setSegmentTooltips(TextBackdrop.allCases.map { $0.title })
        backdropSegments.target = self
        backdropSegments.action = #selector(backdropChanged)

        backdropRow.addArrangedSubview(backdropSegments)
    }

    private func buildShapeStyleRow() {
        shapeStyleRow.orientation = .horizontal
        shapeStyleRow.spacing = 6
        shapeStyleRow.alignment = .centerY
        shapeStyleSegments.segmentCount = 2
        shapeStyleSegments.focusRingType = .none
        shapeStyleSegments.translatesAutoresizingMaskIntoConstraints = false
        shapeStyleSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        shapeStyleSegments.setLabel(L10n.t("style.shapeOutline"), forSegment: 0)
        shapeStyleSegments.setLabel(L10n.t("style.shapeFilled"), forSegment: 1)
        shapeStyleSegments.setWidth(93, forSegment: 0)
        shapeStyleSegments.setWidth(93, forSegment: 1)
        for index in 0..<2 {
            shapeStyleSegments.setToolTip(L10n.t("hint.control.alternate"), forSegment: index)
        }
        shapeStyleSegments.setSegmentTooltips([L10n.t("hint.control.alternate"), L10n.t("hint.control.alternate")])
        shapeStyleSegments.target = self
        shapeStyleSegments.action = #selector(shapeStyleChanged)
        shapeStyleRow.addArrangedSubview(shapeStyleSegments)
    }

    private func buildArrowStyleRow() {
        arrowStyleRow.orientation = .horizontal
        arrowStyleRow.spacing = 6
        arrowStyleRow.alignment = .centerY
        arrowStyleSegments.segmentCount = 2
        arrowStyleSegments.focusRingType = .none
        arrowStyleSegments.translatesAutoresizingMaskIntoConstraints = false
        arrowStyleSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        arrowStyleSegments.setImage(
            NSImage.freshSystemSymbol("arrow.up.right", accessibilityDescription: L10n.t("style.arrowSingle")),
            forSegment: 0
        )
        arrowStyleSegments.setImage(
            NSImage.freshSystemSymbol("arrow.left.and.right", accessibilityDescription: L10n.t("style.arrowDouble")),
            forSegment: 1
        )
        arrowStyleSegments.setWidth(93, forSegment: 0)
        arrowStyleSegments.setWidth(93, forSegment: 1)
        arrowStyleSegments.setToolTip(L10n.t("style.arrowSingle"), forSegment: 0)
        arrowStyleSegments.setToolTip(L10n.t("style.arrowDouble"), forSegment: 1)
        arrowStyleSegments.setSegmentTooltips([L10n.t("style.arrowSingle"), L10n.t("style.arrowDouble")])
        arrowStyleSegments.target = self
        arrowStyleSegments.action = #selector(arrowStyleChanged)
        arrowStyleRow.addArrangedSubview(arrowStyleSegments)
    }

    private func buildMarkerShapeRow() {
        markerShapeRow.orientation = .horizontal
        markerShapeRow.spacing = 6
        markerShapeRow.alignment = .centerY
        markerShapeSegments.segmentCount = MarkerShape.allCases.count
        markerShapeSegments.focusRingType = .none
        markerShapeSegments.translatesAutoresizingMaskIntoConstraints = false
        markerShapeSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for (index, item) in MarkerShape.allCases.enumerated() {
            markerShapeSegments.setImage(
                NSImage.freshSystemSymbol(item.symbolName, accessibilityDescription: item.title),
                forSegment: index
            )
            markerShapeSegments.setWidth(62, forSegment: index)
            markerShapeSegments.setToolTip(item.title, forSegment: index)
        }
        markerShapeSegments.setSegmentTooltips(MarkerShape.allCases.map(\.title))
        markerShapeSegments.target = self
        markerShapeSegments.action = #selector(markerShapeChanged)
        markerShapeRow.addArrangedSubview(markerShapeSegments)
    }

    private func buildEraserShapeRow() {
        eraserShapeRow.orientation = .horizontal
        eraserShapeRow.spacing = 6
        eraserShapeRow.alignment = .centerY
        eraserShapeSegments.segmentCount = ObfuscationShape.allCases.count
        eraserShapeSegments.focusRingType = .none
        eraserShapeSegments.translatesAutoresizingMaskIntoConstraints = false
        eraserShapeSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for (index, item) in ObfuscationShape.allCases.enumerated() {
            eraserShapeSegments.setImage(
                NSImage.freshSystemSymbol(item.symbolName, accessibilityDescription: item.title),
                forSegment: index
            )
            eraserShapeSegments.setWidth(62, forSegment: index)
            eraserShapeSegments.setToolTip(item.title, forSegment: index)
        }
        eraserShapeSegments.setSegmentTooltips(ObfuscationShape.allCases.map { $0.title })
        eraserShapeSegments.target = self
        eraserShapeSegments.action = #selector(eraserShapeChanged)
        eraserShapeRow.addArrangedSubview(eraserShapeSegments)
    }

    private func buildEraserModeRow() {
        eraserModeRow.orientation = .horizontal
        eraserModeRow.spacing = 6
        eraserModeRow.alignment = .centerY
        eraserModeSegments.segmentCount = EraserMode.allCases.count
        eraserModeSegments.focusRingType = .none
        eraserModeSegments.translatesAutoresizingMaskIntoConstraints = false
        eraserModeSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for (index, item) in EraserMode.allCases.enumerated() {
            eraserModeSegments.setLabel(item.title, forSegment: index)
            eraserModeSegments.setWidth(93, forSegment: index)
            eraserModeSegments.setToolTip(item.title, forSegment: index)
        }
        eraserModeSegments.setSegmentTooltips(EraserMode.allCases.map(\.title))
        eraserModeSegments.target = self
        eraserModeSegments.action = #selector(eraserModeChanged)
        eraserModeRow.addArrangedSubview(eraserModeSegments)
    }

    private func buildObfuscationRows() {
        obfuscationStyleRow.orientation = .horizontal
        obfuscationStyleRow.spacing = 6
        obfuscationStyleRow.alignment = .centerY
        obfuscationStyleSegments.segmentCount = ObfuscationStyle.allCases.count
        obfuscationStyleSegments.focusRingType = .none
        obfuscationStyleSegments.translatesAutoresizingMaskIntoConstraints = false
        obfuscationStyleSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for (index, item) in ObfuscationStyle.allCases.enumerated() {
            obfuscationStyleSegments.setLabel(item.title, forSegment: index)
            obfuscationStyleSegments.setWidth(93, forSegment: index)
            obfuscationStyleSegments.setToolTip(L10n.t("hint.control.alternate"), forSegment: index)
        }
        obfuscationStyleSegments.setSegmentTooltips(ObfuscationStyle.allCases.map { _ in L10n.t("hint.control.alternate") })
        obfuscationStyleSegments.target = self
        obfuscationStyleSegments.action = #selector(obfuscationStyleChanged)
        obfuscationStyleRow.addArrangedSubview(obfuscationStyleSegments)

        obfuscationShapeRow.orientation = .horizontal
        obfuscationShapeRow.spacing = 6
        obfuscationShapeRow.alignment = .centerY
        obfuscationShapeSegments.segmentCount = ObfuscationShape.allCases.count
        obfuscationShapeSegments.focusRingType = .none
        obfuscationShapeSegments.translatesAutoresizingMaskIntoConstraints = false
        obfuscationShapeSegments.heightAnchor.constraint(equalToConstant: 24).isActive = true
        for (index, item) in ObfuscationShape.allCases.enumerated() {
            obfuscationShapeSegments.setImage(
                NSImage.freshSystemSymbol(item.symbolName, accessibilityDescription: item.title),
                forSegment: index
            )
            obfuscationShapeSegments.setWidth(62, forSegment: index)
            obfuscationShapeSegments.setToolTip(item.title, forSegment: index)
        }
        obfuscationShapeSegments.setSegmentTooltips(ObfuscationShape.allCases.map { $0.title })
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
        backdropHexField.stringValue = style.backdropColor.hexString
        let width = tool == .counter ? style.counterSize : style.lineWidth
        widthSlider.doubleValue = Double(width)
        widthValue.stringValue = "\(Int(width))"
        widthCaption?.stringValue = L10n.t(tool == .counter ? "style.size" : "style.thickness")
        counterArrowWidthSlider.doubleValue = Double(style.counterArrowWidth)
        counterArrowWidthValue.stringValue = "\(Int(style.counterArrowWidth))"
        fontSlider.doubleValue = Double(style.fontSize)
        fontValue.stringValue = "\(Int(style.fontSize))"
        eraserSlider.doubleValue = Double(style.eraserRadius)
        eraserValue.stringValue = "\(Int(style.eraserRadius))"
        backdropSegments.selectedSegment = TextBackdrop.allCases.firstIndex(of: style.textBackdrop) ?? 0
        shapeStyleSegments.selectedSegment = style.filled ? 1 : 0
        arrowStyleSegments.selectedSegment = style.arrowDoubleHeaded ? 1 : 0
        markerShapeSegments.selectedSegment =
            MarkerShape.allCases.firstIndex(of: style.markerShape) ?? 0
        obfuscationStyleSegments.selectedSegment =
            ObfuscationStyle.allCases.firstIndex(of: style.obfuscation.style) ?? 0
        obfuscationShapeSegments.selectedSegment =
            ObfuscationShape.allCases.firstIndex(of: style.obfuscation.shape) ?? 0
        brushSlider.doubleValue = Double(style.obfuscation.brushSize)
        brushValue.stringValue = "\(Int(style.obfuscation.brushSize))"
        intensitySlider.doubleValue = Double(style.obfuscation.intensity)
        intensityValue.stringValue = "\(Int(style.obfuscation.intensity))"
        eraserModeSegments.selectedSegment = EraserMode.allCases.firstIndex(of: style.eraserMode) ?? 0
        eraserShapeSegments.selectedSegment = ObfuscationShape.allCases.firstIndex(of: style.eraserShape) ?? 0

        applyRowVisibility()
        refreshSelection()
        reloadRecentColors()
        synchronizeOpenColorPanel()
        onContentChanged?()
    }

    private func applyRowVisibility() {
        // Region highlighters are sized by the rubber-band rectangle. Keep the
        // thickness control available for brush mode, but avoid presenting a
        // setting that has no effect for rectangular/oval modes.
        widthRow.isHidden = !tool.supportsLineWidth && tool != .counter
            || (tool == .marker && style.markerShape != .brush)
        counterArrowWidthRow.isHidden = tool != .counter
        fontRow.isHidden = tool != .text
        backdropRow.isHidden = tool != .text
        backdropColorSection.isHidden = tool != .text || !style.textBackdrop.usesBackdropColor
        shapeStyleRow.isHidden = tool != .rectangle && tool != .ellipse
        arrowStyleRow.isHidden = tool != .arrow
        markerShapeRow.isHidden = tool != .marker
        obfuscationStyleRow.isHidden = tool != .obfuscate
        obfuscationShapeRow.isHidden = tool != .obfuscate
        intensityRow.isHidden = tool != .obfuscate
        brushRow.isHidden = !(tool == .obfuscate && style.obfuscation.shape == .brush)
        eraserModeRow.isHidden = tool != .eraser
        eraserShapeRow.isHidden = tool != .eraser || style.eraserMode == .objects
        // The radius slider only means something for the round brush; a
        // rect/ellipse erase region is sized by dragging, not by a setting.
        eraserRow.isHidden = !(tool == .eraser && style.eraserMode == .pixels && style.eraserShape == .brush)

        let anyOption = [widthRow, fontRow, backdropRow, shapeStyleRow, arrowStyleRow,
                         backdropColorSection, counterArrowWidthRow, obfuscationStyleRow,
                         markerShapeRow, obfuscationShapeRow, brushRow, intensityRow, eraserModeRow,
                         eraserShapeRow, eraserRow]
            .contains { !$0.isHidden }
        optionsSeparator.isHidden = !anyOption
    }

    private func refreshSelection() {
        for cell in paletteCells + recentCells {
            cell.isSelectedColor = cell.color.hexString == style.color.hexString
        }
        for cell in backdropPaletteCells + backdropRecentCells {
            cell.isSelectedColor = cell.color.hexString == style.backdropColor.hexString
        }
    }

    private func reloadRecentColors() {
        reloadRecentColors(target: .stroke)
        reloadRecentColors(target: .backdrop)
        refreshSelection()
    }

    private func reloadRecentColors(target: StyleColorTarget) {
        let cells = target == .stroke ? recentCells : backdropRecentCells
        let row = target == .stroke ? recentRow : backdropRecentRow
        let section = target == .stroke ? recentSection : backdropRecentSection
        cells.forEach { $0.removeFromSuperview() }
        if target == .stroke {
            recentCells.removeAll()
        } else {
            backdropRecentCells.removeAll()
        }

        let recents = target == .stroke
            ? Settings.shared.recentStrokeColors
            : Settings.shared.recentBackdropColors
        section.isHidden = recents.isEmpty
        for color in recents.prefix(Settings.maximumRecentColors) {
            let cell = ColorCell(color: color, target: target, side: Self.paletteCellSide)
            cell.target = self
            cell.action = #selector(paletteCellTapped(_:))
            cell.isSelectedColor = target == .stroke
                ? color.hexString == style.color.hexString
                : color.hexString == style.backdropColor.hexString
            if target == .stroke {
                recentCells.append(cell)
            } else {
                backdropRecentCells.append(cell)
            }
            row.addArrangedSubview(cell)
        }
    }

    private func emit() {
        onStyleChange?(style)
    }

    private func applyColor(_ color: NSColor, to target: StyleColorTarget) {
        // Every color here is drawn at full strength — backdrop translucency is
        // its own `textBackdrop` mode, not a per-color alpha — so a color with
        // alpha < 1 (the system panel's Opacity slider, or a pasted 8-digit hex)
        // has no legitimate use and only produces a stroke or backdrop that's
        // partially or fully invisible, with no way back except retyping a hex
        // value from scratch. Force it opaque at the one place every source of a
        // color funnels through.
        let color = color.withAlphaComponent(1)
        noteRecentColor(color, target: target)

        switch target {
        case .stroke:
            style.color = color
            hexField.stringValue = color.hexString
        case .backdrop:
            style.backdropColor = color
            backdropHexField.stringValue = color.hexString
        }
        synchronizeOpenColorPanel()
        refreshSelection()
        emit()
        reloadRecentColors()
        onContentChanged?()
    }

    private func noteRecentColor(_ color: NSColor, target: StyleColorTarget) {
        // The settings object keeps newest-first order and moves an existing
        // color to the front instead of creating duplicates.
        switch target {
        case .stroke: Settings.shared.noteStrokeColorUsed(color)
        case .backdrop: Settings.shared.noteBackdropColorUsed(color)
        }
    }

    private func synchronizeOpenColorPanel() {
        guard ownsColorPanel, !isSynchronizingColorPanel else { return }
        let selected = colorPanelTarget == .stroke ? style.color : style.backdropColor
        let panel = NSColorPanel.shared
        let shown = panel.color.usingColorSpace(.sRGB) ?? panel.color
        guard shown.hexString != selected.hexString else { return }

        isSynchronizingColorPanel = true
        panel.color = selected
        isSynchronizingColorPanel = false
    }

    /// Reflects an eyedropper sample taken on the overlay.
    func updateSampledColor(_ color: NSColor, target: StyleColorTarget) {
        applyColor(color, to: target)
    }

    func setEyedropperActive(_ active: Bool, target: StyleColorTarget = .stroke) {
        eyedropperActive = active
        eyedropperButton.isActive = active && target == .stroke
        backdropEyedropperButton.isActive = active && target == .backdrop
    }

    // MARK: - Actions

    @objc private func paletteCellTapped(_ sender: ColorCell) {
        applyColor(sender.color, to: sender.colorTarget)
    }

    @objc private func hexCommitted(_ sender: NSTextField) {
        let target: StyleColorTarget = sender === backdropHexField ? .backdrop : .stroke
        guard let color = NSColor(hex: sender.stringValue) else {
            sender.stringValue = target == .backdrop ? style.backdropColor.hexString : style.color.hexString
            return
        }
        applyColor(color, to: target)
    }

    @objc private func eyedropperTapped(_ sender: OverlayButton) {
        let target: StyleColorTarget = sender === backdropEyedropperButton ? .backdrop : .stroke
        // Second press cancels, so the crosshair is never a one-way trip.
        let active = !(eyedropperActive &&
            ((target == .stroke && eyedropperButton.isActive) ||
             (target == .backdrop && backdropEyedropperButton.isActive)))
        setEyedropperActive(active, target: target)
        onEyedropperToggled?(active, target)
    }

    @objc private func systemPickerTapped(_ sender: OverlayButton) {
        let target: StyleColorTarget = sender === backdropSystemPicker ? .backdrop : .stroke
        if ownsColorPanel, target == colorPanelTarget {
            detachSystemColorPanel()
        } else {
            openSystemColorPanel(for: target)
        }
    }

    private func openSystemColorPanel(for target: StyleColorTarget) {
        colorPanelTarget = target
        let panel = NSColorPanel.shared
        let selected = target == .stroke ? style.color : style.backdropColor

        // Detach while assigning the initial value. This prevents AppKit from
        // treating our synchronization as a user selection and adding a
        // duplicate Recent color.
        panel.setTarget(nil)
        panel.setAction(nil)
        // Stroke and backdrop colors are always drawn opaque (see `applyColor`),
        // so the Opacity slider has nothing valid to do here — and left in, it is
        // how the backdrop color ended up silently transparent before.
        panel.showsAlpha = false
        panel.color = selected
        // Only deliver the final color after the user finishes an interaction.
        // Continuous delivery makes every intermediate drag position a Recent
        // color and can leave the final action deferred until another event.
        panel.isContinuous = false
        // The overlay sits at shielding level, so the panel has to be lifted above
        // it or the user would click a button and see nothing appear.
        panel.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 2)
        panel.hidesOnDeactivate = false
        panel.setTarget(self)
        panel.setAction(#selector(systemColorChanged(_:)))
        // Order front FIRST: a panel that has never been shown in this process
        // reports a stale/zero `frame.size` until AppKit actually lays it out,
        // and positioning against that size would leave it placed as an
        // effectively invisible zero-size window. Reposition it only once its
        // real, on-screen size is known.
        panel.makeKeyAndOrderFront(nil)
        positionColorPanel(panel)
        ownsColorPanel = true
        updateSystemPickerButtonStates()
        observeColorPanelClosing(panel)
    }

    private func updateSystemPickerButtonStates() {
        systemPicker.isActive = ownsColorPanel && colorPanelTarget == .stroke
        backdropSystemPicker.isActive = ownsColorPanel && colorPanelTarget == .backdrop
    }

    private func observeColorPanelClosing(_ panel: NSColorPanel) {
        guard colorPanelCloseObserver == nil else { return }
        colorPanelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.colorPanelDidClose()
        }
    }

    private func colorPanelDidClose() {
        ownsColorPanel = false
        updateSystemPickerButtonStates()
        removeColorPanelCloseObserver()
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
    }

    private func removeColorPanelCloseObserver() {
        if let colorPanelCloseObserver {
            NotificationCenter.default.removeObserver(colorPanelCloseObserver)
            self.colorPanelCloseObserver = nil
        }
    }

    /// `NSColorPanel.shared` is a single system-wide window that remembers
    /// wherever it was last left — on another display, or one that is no
    /// longer connected, that reads as "the color picker doesn't open near
    /// what I'm doing." Pin it beside this popover, on the popover's own
    /// screen, every time.
    private func positionColorPanel(_ panel: NSColorPanel) {
        guard let window else { return }
        let screenFrame = window.convertToScreen(convert(bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: screenFrame.midX, y: screenFrame.midY)) }
            ?? window.screen ?? NSScreen.main
        guard let screen else { return }

        let panelSize = panel.frame.size
        guard panelSize.width > 1, panelSize.height > 1 else { return }
        var origin = CGPoint(x: screenFrame.maxX + 12, y: screenFrame.maxY - panelSize.height)
        if origin.x + panelSize.width > screen.frame.maxX {
            origin.x = screenFrame.minX - 12 - panelSize.width
        }
        origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - panelSize.width - 4)
        origin.y = min(max(origin.y, screen.frame.minY + 4), screen.frame.maxY - panelSize.height - 4)
        panel.setFrameOrigin(origin)
    }

    @objc private func systemColorChanged(_ sender: NSColorPanel) {
        guard !isSynchronizingColorPanel else { return }
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        applyColor(color, to: colorPanelTarget)
    }

    @objc private func widthChanged() {
        let value = CGFloat(widthSlider.doubleValue.rounded())
        if tool == .counter {
            style.counterSize = value
        } else {
            style.lineWidth = value
        }
        widthValue.stringValue = "\(Int(value))"
        emit()
    }

    @objc private func counterArrowWidthChanged() {
        style.counterArrowWidth = CGFloat(counterArrowWidthSlider.doubleValue.rounded())
        counterArrowWidthValue.stringValue = "\(Int(style.counterArrowWidth))"
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
        backdropColorSection.isHidden = !style.textBackdrop.usesBackdropColor
        emit()
        onContentChanged?()
    }

    @objc private func shapeStyleChanged() {
        style.filled = shapeStyleSegments.selectedSegment == 1
        emit()
    }

    @objc private func arrowStyleChanged() {
        style.arrowDoubleHeaded = arrowStyleSegments.selectedSegment == 1
        emit()
    }

    @objc private func markerShapeChanged() {
        let index = markerShapeSegments.selectedSegment
        guard index >= 0, index < MarkerShape.allCases.count else { return }
        style.markerShape = MarkerShape.allCases[index]
        applyRowVisibility()
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

    @objc private func eraserShapeChanged() {
        let index = eraserShapeSegments.selectedSegment
        guard index >= 0, index < ObfuscationShape.allCases.count else { return }
        style.eraserShape = ObfuscationShape.allCases[index]
        eraserRow.isHidden = style.eraserShape != .brush
        emit()
        onContentChanged?()
    }

    @objc private func eraserModeChanged() {
        let index = eraserModeSegments.selectedSegment
        guard index >= 0, index < EraserMode.allCases.count else { return }
        style.eraserMode = EraserMode.allCases[index]
        applyRowVisibility()
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
        ownsColorPanel = false
        updateSystemPickerButtonStates()
        removeColorPanelCloseObserver()
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        panel.level = .floating
    }
}
