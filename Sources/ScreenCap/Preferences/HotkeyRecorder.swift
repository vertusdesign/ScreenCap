import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click-to-record shortcut field.
final class HotkeyRecorderView: NSView {
    var hotkey: Hotkey? { didSet { needsDisplay = true } }
    var onChange: ((Hotkey?) -> Void)?

    private var isRecording = false { didSet { needsDisplay = true; updateMonitor() } }
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording.toggle()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if isRecording { HotkeyManager.shared.resume() }
    }

    private func updateMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard isRecording else {
            HotkeyManager.shared.resume()
            return
        }
        // While THIS field is capturing, the combo it currently shows must not
        // ALSO fire its old action — Carbon hotkeys are registered at the window
        // server and fire regardless of which view has keyboard focus.
        HotkeyManager.shared.suspend()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, isRecording else { return event }
            guard event.type == .keyDown else { return nil }

            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) {
                hotkey = nil
                onChange?(nil)
                isRecording = false
                return nil
            }

            let candidate = Hotkey(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
            guard candidate.isValid else { return nil }
            hotkey = candidate
            onChange?(candidate)
            isRecording = false
            return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        background.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        background.lineWidth = isRecording ? 2 : 1
        background.stroke()

        let text: String
        if isRecording {
            text = L10n.t("hotkey.recording")
        } else if let hotkey {
            text = hotkey.displayString
        } else {
            text = L10n.t("hotkey.unset")
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: hotkey == nil && !isRecording ? NSColor.tertiaryLabelColor : NSColor.labelColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    let hotkey: Hotkey?
    let onChange: (Hotkey?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.hotkey = hotkey
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        nsView.hotkey = hotkey
        nsView.onChange = onChange
    }
}
