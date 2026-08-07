import AppKit

/// Vertical strip of drawing tools shown beside the selection.
final class ToolStrip: OverlayPanel {
    /// Order shown top-to-bottom; `.move` first so the default state is "adjust
    /// the selection", exactly like Lightshot.
    static let tools: [ToolKind] = [
        .move, .pen, .marker, .line, .arrow,
        .rectangle, .ellipse, .obfuscate, .counter, .text, .eraser
    ]

    var onToolSelected: ((ToolKind) -> Void)?
    var onStyleTapped: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private var buttons: [ToolKind: OverlayButton] = [:]
    private let swatch = ColorSwatchButton()
    private let undoButton = OverlayButton(
        symbolName: "arrow.uturn.backward",
        tooltip: L10n.t("action.undo"),
        shortcut: "⌘Z"
    )
    private let redoButton = OverlayButton(
        symbolName: "arrow.uturn.forward",
        tooltip: L10n.t("action.redo"),
        shortcut: "⇧⌘Z"
    )

    private var showsAlternate = false
    private var obfuscationStyle: ObfuscationStyle = .pixelate

    override init() {
        super.init()
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = OverlayStyle.buttonSpacing
        stack.edgeInsets = NSEdgeInsets(
            top: OverlayStyle.panelPadding, left: OverlayStyle.panelPadding,
            bottom: OverlayStyle.panelPadding, right: OverlayStyle.panelPadding
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for (index, tool) in Self.tools.enumerated() {
            let button = OverlayButton(
                symbolName: tool.symbolName,
                tooltip: tool.title,
                shortcut: tool.shortcutKey
            )
            button.target = self
            button.action = #selector(toolTapped(_:))
            button.tag = index
            buttons[tool] = button
            stack.addArrangedSubview(button)
        }

        let separator = NSView.overlaySeparator(vertical: false)
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: OverlayStyle.buttonSize - 8).isActive = true

        swatch.target = self
        swatch.action = #selector(styleTapped)
        swatch.toolTip = L10n.t("action.style")
        stack.addArrangedSubview(swatch)

        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        redoButton.target = self
        redoButton.action = #selector(redoTapped)
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
    }

    private var selectedTool: ToolKind = .move

    func setSelected(_ tool: ToolKind) {
        selectedTool = tool
        for (kind, button) in buttons { button.isActive = kind == tool }
        refreshSymbols()
    }

    /// Colour currently applied to the tools, so a tool switch can preserve it.
    private(set) var currentColor: NSColor?

    func setColor(_ color: NSColor) {
        swatch.color = color
        currentColor = color
    }

    /// Shows the ⌃-alternate icon for whichever tools have one.
    func setAlternate(_ alternate: Bool, obfuscationStyle: ObfuscationStyle) {
        guard alternate != showsAlternate || obfuscationStyle != self.obfuscationStyle else { return }
        showsAlternate = alternate
        self.obfuscationStyle = obfuscationStyle
        refreshSymbols()
    }

    private func refreshSymbols() {
        for (kind, button) in buttons {
            // Only the selected tool morphs: swapping every icon at once would be
            // noise, since ⌃ applies to whatever is actually being drawn.
            let alternate = showsAlternate && kind == selectedTool && kind.hasAlternate
            button.setSymbol(kind.symbolName(alternate: alternate, obfuscationStyle: obfuscationStyle))
            if kind == .obfuscate || kind.hasAlternate {
                button.setTooltip(
                    kind.title,
                    shortcut: kind.shortcutKey,
                    hint: kind.hasAlternate ? L10n.t("hint.control.alternate") : nil
                )
            }
        }
    }

    func setHistoryState(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.35
        redoButton.alphaValue = canRedo ? 1 : 0.35
    }

    @objc private func toolTapped(_ sender: OverlayButton) {
        guard sender.tag < Self.tools.count else { return }
        onToolSelected?(Self.tools[sender.tag])
    }

    @objc private func styleTapped() { onStyleTapped?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
}

/// Horizontal bar of terminal actions shown under the selection.
final class ActionBar: OverlayPanel {
    var onCopy: (() -> Void)?
    /// `true` when ⇧ was held, which asks for the save panel.
    var onSave: ((Bool) -> Void)?
    var onPrint: (() -> Void)?
    var onCancel: (() -> Void)?

    override init() {
        super.init()
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let cancel = OverlayButton(
            symbolName: "xmark",
            tooltip: L10n.t("action.cancel"),
            shortcut: "Esc",
            size: 26
        )
        cancel.target = self
        cancel.action = #selector(cancelTapped)

        let print = OverlayButton(
            symbolName: "printer",
            tooltip: L10n.t("action.print"),
            shortcut: "⌘P",
            size: 26
        )
        print.target = self
        print.action = #selector(printTapped)

        // One save button: a plain click saves, ⇧-click asks where.
        let save = OverlayButton(
            symbolName: "square.and.arrow.down",
            tooltip: L10n.t("action.save"),
            shortcut: "⌘S",
            hint: L10n.t("hint.shift.saveAs"),
            size: 26
        )
        save.target = self
        save.action = #selector(saveTapped)

        let copy = OverlayButton(
            symbolName: "doc.on.doc",
            tooltip: L10n.t("action.copy"),
            shortcut: "⌘C",
            size: 26,
            accented: true
        )
        copy.target = self
        copy.action = #selector(copyTapped)

        stack.addArrangedSubview(cancel)
        stack.addArrangedSubview(print)
        stack.addArrangedSubview(save)
        stack.addArrangedSubview(copy)
    }

    @objc private func copyTapped() { onCopy?() }

    @objc private func saveTapped() {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        onSave?(shiftHeld)
    }

    @objc private func printTapped() { onPrint?() }
    @objc private func cancelTapped() { onCancel?() }
}
