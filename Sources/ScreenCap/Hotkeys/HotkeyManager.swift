import AppKit
import Carbon.HIToolbox

/// Actions that can be bound to a global shortcut.
enum HotkeyAction: String, CaseIterable, Codable {
    case captureArea
    case repeatLastArea
    case captureWindow
    case captureFullScreen

    var title: String { L10n.t("hotkey.\(rawValue)") }

    var symbolName: String {
        switch self {
        case .captureArea: return "selection.pin.in.out"
        case .repeatLastArea: return "arrow.clockwise.square"
        case .captureWindow: return "macwindow"
        case .captureFullScreen: return "rectangle.inset.filled"
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
        }
    }
}

/// Registers system-wide shortcuts through Carbon's hot key API.
///
/// Carbon is used deliberately: it is the only route to a global shortcut that does
/// not require the Accessibility permission, and it is purely event-driven, so the
/// app burns no CPU while idle.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private struct Registration {
        let ref: EventHotKeyRef
        let action: HotkeyAction
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x534C_5348 // 'SLSH'

    var handler: ((HotkeyAction) -> Void)?

    /// Shortcuts the system refused, almost always because another app owns them.
    /// Surfaced in Preferences so a silently dead hotkey is never a mystery.
    private(set) var failedActions: Set<HotkeyAction> = []

    private init() {}

    // MARK: - Registration

    /// Replaces every registration with the given bindings.
    func apply(_ bindings: [HotkeyAction: Hotkey]) {
        installEventHandlerIfNeeded()
        unregisterAll()
        failedActions.removeAll()
        for (action, hotkey) in bindings where hotkey.isValid {
            register(hotkey, for: action)
        }
        NotificationCenter.default.post(name: .hotkeyRegistrationChanged, object: nil)
    }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
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

    private func register(_ hotkey: Hotkey, for action: HotkeyAction) {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            failedActions.insert(action)
            NSLog("ScreenCap: could not register \(hotkey.displayString) (status \(status)) — most likely taken by another app")
            return
        }
        registrations[id] = Registration(ref: ref, action: action)
    }

    // MARK: - Event handling

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
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
        DispatchQueue.main.async { [weak self] in
            self?.handler?(action)
        }
        return noErr
    }
}

extension Notification.Name {
    /// Posted after `HotkeyManager.apply(_:)` so Preferences can refresh its
    /// conflict warnings.
    static let hotkeyRegistrationChanged = Notification.Name("ScreenCap.hotkeyRegistrationChanged")
}
