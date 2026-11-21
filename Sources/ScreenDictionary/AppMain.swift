import AppKit
import ApplicationServices
import SwiftUI

@main
enum ScreenDictionaryApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var overlay = OverlayCoordinator(preferences: preferences)
    private lazy var input = GlobalInput(preferences: preferences)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var warmedEngine: EngineSettings?
    private var warmTask: Task<Void, Never>?
    private var reopening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeStatusItem()
        overlay.onIssue = { [weak self] error in self?.showIssue(error) }
        input.onTrigger = { [weak self] kind, point in self?.overlay.trigger(kind, at: point) }
        input.onControllerAction = { [weak self] action in self?.overlay.handleController(action) }
        input.dismissFromOtherDisplay = { [weak self] point in self?.overlay.dismissFromOtherDisplay(point) }
        input.overlayIsVisible = { [weak self] in self?.overlay.isVisible ?? false }
        input.start()
        preferences.onConfigurationChange = { [weak self] in self?.configurationChanged() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenLayoutChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        refreshPermissions()
        if !preferences.config.openedSettings || !preferences.screenPermission
            || CommandLine.arguments.contains("--show-settings") {
            if !preferences.config.openedSettings { preferences.config.openedSettings = true }
            openSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.dismiss(restoreFocus: false)
        warmTask?.cancel()
        input.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func makeStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "屏幕词典")
        if statusItem.button?.image == nil { statusItem.button?.title = "词" }
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let configuration = preferences.config
        for mode in ScreenMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil)
            item.state = configuration.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出屏幕词典", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.toolTip = "屏幕词典 · \(configuration.mode.title) · \(configuration.keyboard.title)"
    }

    private func configurationChanged() {
        input.refresh()
        updateMenu()
        warmModelIfNeeded()
    }

    private func refreshPermissions() {
        let screenAvailable = CGPreflightScreenCaptureAccess()
        if preferences.screenPermission != screenAvailable { preferences.screenPermission = screenAvailable }
        input.refresh()
        warmModelIfNeeded()
    }

    @objc private func settingsBecameKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            refreshPermissions()
        }
    }

    @objc private func changeMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let mode = ScreenMode(rawValue: raw) else { return }
        overlay.dismiss(restoreFocus: false)
        preferences.config.mode = mode
    }

    @objc private func openSettings() {
        overlay.dismiss(restoreFocus: false)
        if settingsWindow == nil {
            let view = SettingsView(
                preferences: preferences,
                getScreenPermission: { [weak self] in self?.requestScreenPermission() },
                getMousePermission: { [weak self] in self?.input.promptForMousePermission() },
                openScreenSettings: { [weak self] in self?.openPrivacySettings("Privacy_ScreenCapture") },
                openMouseSettings: { [weak self] in self?.openPrivacySettings("Privacy_Accessibility") },
                refreshPermissions: { [weak self] in self?.refreshPermissions() },
                reopenApplication: { [weak self] in self?.reopenApplication() },
                setRecording: { [weak self] enabled in self?.input.setRecording(enabled) }
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 625, height: 555),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "屏幕词典设置"
            window.minSize = NSSize(width: 570, height: 500)
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.center()
            settingsWindow = window
        }
        refreshPermissions()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func requestScreenPermission() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        refreshPermissions()
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reopenApplication() {
        guard !reopening else { return }
        reopening = true
        overlay.dismiss(restoreFocus: false)
        input.setRecording(true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--show-settings"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] app, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let app, app.processIdentifier != getpid() {
                    NSApp.terminate(nil)
                } else {
                    self.reopening = false
                    self.input.setRecording(false)
                    let alert = NSAlert()
                    alert.messageText = "未能重新打开屏幕词典"
                    alert.informativeText = "请从菜单栏退出屏幕词典，再打开应用包。"
                    if let window = self.settingsWindow { alert.beginSheetModal(for: window) }
                }
            }
        }
    }

    private func showIssue(_ message: String) {
        openSettings()
        if !preferences.screenPermission { return }
        guard let settingsWindow, settingsWindow.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "无法读取屏幕"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: settingsWindow)
    }

    private func warmModelIfNeeded() {
        let config = preferences.config
        let engine = config.engine(for: config.mode)
        guard preferences.screenPermission, config.textEngine(for: config.mode) == .model, engine.kind == .ollama else {
            warmTask?.cancel()
            warmTask = nil
            warmedEngine = nil
            return
        }
        guard warmedEngine != engine else { return }
        warmedEngine = engine
        warmTask?.cancel()
        warmTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await TranslationClient(configuration: config, appName: "").warmLocalModel()
        }
    }

    @objc private func screenLayoutChanged() {
        ScreenCapture.displayLayoutChanged()
        overlay.dismiss(restoreFocus: false)
    }

    @objc private func activeAppChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            overlay.appActivated(app)
        }
    }
}
