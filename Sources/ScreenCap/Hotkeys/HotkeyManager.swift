import AppKit
import Carbon.HIToolbox

/// Actions that can be bound to a global shortcut.
enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case captureArea
    case repeatLastArea
    case captureWindow
    case captureFullScreen
    case toggleRecording
    case chooseRecordingDisplay
    case toggleRecordingMicrophone
    case toggleRecordingSystemAudio

    var title: String { L10n.t("hotkey.\(rawValue)") }

    var isAvailable: Bool {
        switch self {
        case .toggleRecording, .chooseRecordingDisplay, .toggleRecordingMicrophone, .toggleRecordingSystemAudio:
            if #available(macOS 15.0, *) { return true }
            return false
        default:
            return true
        }
    }

    var symbolName: String {
        switch self {
        case .captureArea: return "selection.pin.in.out"
        case .repeatLastArea: return "arrow.clockwise.square"
        case .captureWindow: return "macwindow"
        case .captureFullScreen: return "rectangle.inset.filled"
        case .toggleRecording: return "record.circle"
        case .chooseRecordingDisplay: return "rectangle.2.swap"
        case .toggleRecordingMicrophone: return "mic.fill"
        case .toggleRecordingSystemAudio: return "speaker.wave.2.fill"
        }
    }

    var defaultHotkey: Hotkey? {
        switch self {
        // Matches the user's existing Lightshot binding.
        case .captureArea: return Hotkey(keyCode: UInt16(kVK_F2), modifierFlags: .command)
        case .repeatLastArea: return Hotkey(keyCode: UInt16(kVK_F3), modifierFlags: .command)
        case .captureWindow: return Hotkey(keyCode: UInt16(kVK_F4), modifierFlags: .command)
        // Plain ⌘F5 collides with the system VoiceOver shortcut and never
        // reaches the app; ⌘⌥F4 sits next to "capture window" (⌘F4) but with a
        // different modifier, so the two never conflict.
        case .captureFullScreen: return Hotkey(keyCode: UInt16(kVK_F4), modifierFlags: [.command, .option])
        // Recording is deliberately next to the screenshot shortcuts without
        // reusing any of them. It is ignored on macOS 14, where the recorder is
        // unavailable but the static screenshot feature remains supported.
        case .toggleRecording: return Hotkey(keyCode: UInt16(kVK_F2), modifierFlags: [.command, .option])
        case .chooseRecordingDisplay: return Hotkey(keyCode: UInt16(kVK_F2), modifierFlags: [.command, .option, .shift])
        case .toggleRecordingMicrophone: return Hotkey(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.command, .option, .shift])
        case .toggleRecordingSystemAudio: return Hotkey(keyCode: UInt16(kVK_ANSI_S), modifierFlags: [.command, .option, .shift])
        }
    }
}

/// Registers system-wide shortcuts through Carbon's hot key API.
///
/// Carbon is used deliberately: it is the only route to a global shortcut that does
/// not require the Accessibility permission, and it is purely event-driven, so the
/// app burns no CPU while idle.
final class HotkeyManager: @unchecked Sendable {
    static let shared = HotkeyManager()

    private struct Registration {
        let ref: EventHotKeyRef
        let action: HotkeyAction
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var localMonitor: Any?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x534C_5348 // 'SLSH'

    var handler: ((HotkeyAction) -> Void)?

    /// Shortcuts the system refused, almost always because another app owns them.
    /// Surfaced in Preferences so a silently dead hotkey is never a mystery.
    private(set) var failedActions: Set<HotkeyAction> = []
    private var localBindings: [HotkeyAction: Hotkey] = [:]
    private var lastTriggered: (HotkeyAction, TimeInterval)?

    private init() {}

    // MARK: - Registration

    /// Replaces every registration with the given bindings.
    func apply(_ bindings: [HotkeyAction: Hotkey]) {
        installEventHandlerIfNeeded()
        unregisterAll()
        failedActions.removeAll()
        localBindings.removeAll()
        for (action, hotkey) in bindings where action.isAvailable && hotkey.isValid {
            if register(hotkey, for: action) {
                localBindings[action] = hotkey
            }
        }
        NotificationCenter.default.post(name: .hotkeyRegistrationChanged, object: nil)
    }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        localBindings.removeAll()
    }

    private var isSuspended = false

    /// Stops answering every global shortcut while a `HotkeyRecorderView` is
    /// capturing a new combination. Carbon hotkeys fire from the window server
    /// independently of which app or field has keyboard focus, so without this,
    /// pressing the very combo already bound to an action — the obvious thing to
    /// do while re-recording it — would fire that action at the same time.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    /// Restores whatever is currently in `Settings`, whether recording ended in
    /// a committed change, a clear, or a cancel that left the old binding intact.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        apply(Settings.shared.hotkeys)
    }

    /// Delivers a shortcut selected from the status-item menu through the same
    /// deduplicated path as Carbon and the local fallback monitor. A menu key
    /// equivalent and a Carbon notification can describe the same physical
    /// key press, so keeping one dispatch path prevents a double capture.
    func triggerFromMenu(_ action: HotkeyAction) {
        guard !isSuspended else { return }
        dispatch(action)
    }

    @discardableResult
    private func register(_ hotkey: Hotkey, for action: HotkeyAction) -> Bool {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            hotKeyID,
            // Route the hot key through the application event queue. The
            // dispatcher target can be starved by AppKit's nested menu
            // tracking loop (status-item, context and popover menus).
            // Application-target registrations remain global: WindowServer
            // posts them to this app even when another app has focus.
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            failedActions.insert(action)
            NSLog("ScreenCap: could not register \(hotkey.displayString) (status \(status)) — most likely taken by another app")
            return false
        }
        registrations[id] = Registration(ref: ref, action: action)
        return true
    }

    // MARK: - Event handling

    private func installEventHandlerIfNeeded() {
        installLocalFallbackIfNeeded()
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            // Keep the handler on the same target used for registration so it
            // continues to run while NSMenu is tracking a nested menu.
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event)
            },
            1,
            &eventType,
            context,
            &eventHandler
        )
    }

    /// AppKit menu tracking can run a nested event loop in which a Carbon hot
    /// key notification is delayed until the menu closes. A local monitor is a
    /// narrow fallback for shortcuts while this app owns the focused menu or
    /// popover. Carbon remains the source for global/background shortcuts.
    private func installLocalFallbackIfNeeded() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isSuspended,
                  let action = self.localAction(for: event) else { return event }
            self.dispatch(action)
            return nil
        }
    }

    private func localAction(for event: NSEvent) -> HotkeyAction? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return localBindings.first(where: { action, hotkey in
            action.isAvailable && hotkey.keyCode == event.keyCode && hotkey.cocoaModifiers == flags
        })?.key
    }

    private func dispatch(_ action: HotkeyAction) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTriggered,
           lastTriggered.0 == action,
           now - lastTriggered.1 < 0.20 {
            return
        }
        lastTriggered = (action, now)
        DispatchQueue.main.async { [weak self] in self?.handler?(action) }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == signature,
              let registration = registrations[hotKeyID.id]
        else { return OSStatus(eventNotHandledErr) }

        let action = registration.action
        dispatch(action)
        return noErr
    }
}

extension Notification.Name {
    /// Posted after `HotkeyManager.apply(_:)` so Preferences can refresh its
    /// conflict warnings.
    static let hotkeyRegistrationChanged = Notification.Name("ScreenCap.hotkeyRegistrationChanged")
}
