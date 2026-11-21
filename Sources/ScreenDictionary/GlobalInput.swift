import AppKit
import ApplicationServices
import Carbon
import GameController

enum TriggerSource {
    case keyboard, mouse, controller
}

enum ControllerAction {
    case step(Int)
    case confirm
    case close
    case speak
    case scroll(CGFloat)
}

@MainActor
final class GlobalInput {
    private let preferences: Preferences
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var registeredKey: KeyShortcut?
    private var mouseTap: CFMachPort?
    private var mouseSource: CFRunLoopSource?
    private var suppressUntilRelease = Set<Int>()
    private var dismissOnRelease: [Int: () -> Void] = [:]
    private var controllerObserver: NSObjectProtocol?
    private var recording = false
    private var lastScroll: TimeInterval = 0

    var onTrigger: ((TriggerSource, CGPoint) -> Void)?
    var onControllerAction: ((ControllerAction) -> Void)?
    var dismissFromOtherDisplay: ((CGPoint) -> (() -> Void)?)?
    var overlayIsVisible: (() -> Bool)?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let input = Unmanaged<GlobalInput>.fromOpaque(data).takeUnretainedValue()
                input.sendTrigger(.keyboard, at: NSEvent.mouseLocation)
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

        GCController.shouldMonitorBackgroundEvents = true
        GCController.controllers().forEach(bind)
        controllerObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            MainActor.assumeIsolated { self?.bind(controller) }
        }
        refresh()
    }

    func refresh() {
        if !recording, registeredKey != preferences.config.keyboard {
            registerKeyboard()
        }
        refreshMouseAccess()
    }

    func promptForMousePermission() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
        refreshMouseAccess()
    }

    private func refreshMouseAccess() {
        let access: MouseAccess
        if AXIsProcessTrusted() {
            if let mouseTap, CFMachPortIsValid(mouseTap) {
                if !CGEvent.tapIsEnabled(tap: mouseTap) {
                    CGEvent.tapEnable(tap: mouseTap, enable: true)
                }
            } else {
                stopMouseTap()
                startMouseTap()
            }
            access = mouseTap.map { CGEvent.tapIsEnabled(tap: $0) } == true ? .available : .listenerUnavailable
        } else {
            stopMouseTap()
            access = .needsAuthorization
        }
        if preferences.mouseAccess != access { preferences.mouseAccess = access }
    }

    func setRecording(_ enabled: Bool) {
        guard recording != enabled else { return }
        recording = enabled
        if enabled {
            unregisterKeyboard()
        } else {
            refresh()
        }
    }

    func stop() {
        unregisterKeyboard()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        stopMouseTap()
        if let controllerObserver { NotificationCenter.default.removeObserver(controllerObserver) }
    }

    private func stopMouseTap() {
        if let mouseSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseSource, .commonModes) }
        if let mouseTap { CFMachPortInvalidate(mouseTap) }
        mouseSource = nil
        mouseTap = nil
        suppressUntilRelease.removeAll()
        dismissOnRelease.removeAll()
    }

    private func registerKeyboard() {
        unregisterKeyboard()
        let shortcut = preferences.config.keyboard
        var flags: UInt32 = 0
        if shortcut.modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if shortcut.modifiers.contains(.command) { flags |= UInt32(cmdKey) }

        let keyID = EventHotKeyID(signature: 0x53444354, id: 1)
        let result = RegisterEventHotKey(shortcut.code, flags, keyID, GetApplicationEventTarget(), 0, &hotKey)
        // Keep the attempted binding, so editing an unrelated preference does not register it again.
        registeredKey = shortcut
        preferences.keyboardIssue = result == noErr ? nil : "系统未能注册 \(shortcut.title)。请换一组快捷键。"
    }

    private func unregisterKeyboard() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredKey = nil
    }

    private func sendTrigger(_ source: TriggerSource, at point: CGPoint) {
        guard !recording else { return }
        onTrigger?(source, point)
    }

    private func startMouseTap() {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, data in
                guard let data else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let input = Unmanaged<GlobalInput>.fromOpaque(data).takeUnretainedValue()
                    return input.handleMouse(type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        mouseTap = tap
        mouseSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleMouse(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            suppressUntilRelease.removeAll()
            dismissOnRelease.removeAll()
            if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            if suppressUntilRelease.remove(button) != nil {
                if let dismiss = dismissOnRelease.removeValue(forKey: button) {
                    Task { @MainActor in dismiss() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let shortcut = preferences.config.mouse
        let flags = ShortcutModifiers(flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        let point = NSScreen.screens.first.map { screen in
            CGPoint(x: event.location.x, y: screen.frame.maxY - event.location.y)
        } ?? NSEvent.mouseLocation
        if !recording, shortcut.isUsable, shortcut.button.rawValue == button, shortcut.modifiers == flags {
            suppressUntilRelease.insert(button)
            Task { @MainActor [weak self] in self?.sendTrigger(.mouse, at: point) }
            return nil
        }

        if let dismiss = dismissFromOtherDisplay?(point) {
            suppressUntilRelease.insert(button)
            dismissOnRelease[button] = dismiss
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func bind(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let triggers: [(ControllerButton, GCControllerButtonInput?)] = [
            (.menu, gamepad.buttonMenu), (.options, gamepad.buttonOptions),
            (.leftShoulder, gamepad.leftShoulder), (.rightShoulder, gamepad.rightShoulder),
            (.leftStick, gamepad.leftThumbstickButton), (.rightStick, gamepad.rightThumbstickButton)
        ]
        for (button, input) in triggers {
            input?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.preferences.config.controller == button else { return }
                    self.sendTrigger(.controller, at: NSEvent.mouseLocation)
                }
            }
        }

        let controls: [(GCControllerButtonInput, ControllerAction)] = [
            (gamepad.dpad.left, .step(-1)), (gamepad.dpad.right, .step(1)),
            (gamepad.dpad.up, .step(-1)), (gamepad.dpad.down, .step(1)),
            (gamepad.buttonA, .confirm), (gamepad.buttonB, .close), (gamepad.buttonY, .speak)
        ]
        for (input, action) in controls {
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor [weak self] in self?.onControllerAction?(action) }
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, _, y in
            guard abs(y) >= 0.36 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.overlayIsVisible?() == true else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastScroll >= 0.07 else { return }
                self.lastScroll = now
                self.onControllerAction?(.scroll(CGFloat(y) * 28))
            }
        }
    }
}
