import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let getScreenPermission: () -> Void
    let getMousePermission: () -> Void
    let openScreenSettings: () -> Void
    let openMouseSettings: () -> Void
    let refreshPermissions: () -> Void
    let reopenApplication: () -> Void
    let setRecording: (Bool) -> Void

    @State private var section = 0
    @State private var engineMode: ScreenMode = .dictionary
    @State private var keyMonitor: Any?
    @State private var keyHint: String?
    @State private var keyDraft = ""
    @State private var keyStatus = ""
    @State private var selectedApp = ""
    @State private var runningApps: [AppProfile] = []

    var body: some View {
        TabView(selection: $section) {
            general.tabItem { Label("常用", systemImage: "slider.horizontal.3") }.tag(0)
            language.tabItem { Label("翻译与词典", systemImage: "character.bubble") }.tag(1)
            apps.tabItem { Label("应用", systemImage: "macwindow.on.rectangle") }.tag(2)
        }
        .padding(14)
        .frame(minWidth: 570, idealWidth: 620, minHeight: 490, idealHeight: 530)
        .onAppear(perform: listApps)
        .onDisappear(perform: endRecording)
        .onChange(of: section) { _, _ in endRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if keyMonitor != nil { endRecording() }
        }
    }

    private var general: some View {
        Form {
            Section("使用方式") {
                Picker("当前模式", selection: $preferences.config.mode) {
                    ForEach(ScreenMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                Text("指向屏幕文字后触发。查词时显示词义，翻译时指向空白可处理整屏。松开鼠标即可从结果外退出。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("全局触发") {
                LabeledContent("键盘") {
                    Button(keyMonitor == nil ? preferences.config.keyboard.title : "按下新的组合键…") {
                        if keyMonitor == nil { recordKey() } else { endRecording() }
                    }
                    .help("点击后录入快捷键，按 Esc 取消")
                }
                if let hint = keyHint ?? preferences.keyboardIssue {
                    Text(hint).font(.callout).foregroundStyle(.orange)
                }
                Toggle("鼠标快捷键", isOn: $preferences.config.mouse.enabled)
                if preferences.config.mouse.enabled {
                    LabeledContent("鼠标组合") {
                        HStack(spacing: 7) {
                            ForEach([
                                (ShortcutModifiers.control, "⌃"),
                                (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
                            ], id: \.0) { modifier, title in
                                Toggle(title, isOn: mouseModifier(modifier)).toggleStyle(.button)
                            }
                            Picker("按键", selection: $preferences.config.mouse.button) {
                                ForEach(MouseButton.allCases) { button in Text(button.title).tag(button) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                    if !preferences.config.mouse.isUsable {
                        Text("左键和右键需要配合至少一个修饰键。").font(.callout).foregroundStyle(.orange)
                    }
                }
                Picker("手柄触发键", selection: $preferences.config.controller) {
                    ForEach(ControllerButton.allCases) { button in Text(button.title).tag(button) }
                }
            }

            Section("系统权限") {
                LabeledContent("屏幕录制") {
                    permission(
                        status: preferences.screenPermission ? "当前版本可用" : "当前进程未获准",
                        available: preferences.screenPermission,
                        request: preferences.screenPermission ? nil : getScreenPermission,
                        openSettings: openScreenSettings
                    )
                }
                LabeledContent("鼠标组合键（辅助功能）") {
                    permission(
                        status: mouseStatus,
                        available: preferences.mouseAccess == .available,
                        request: preferences.mouseAccess == .needsAuthorization ? getMousePermission : nil,
                        openSettings: openMouseSettings
                    )
                }
                if !preferences.screenPermission || preferences.mouseAccess != .available {
                    Text("在系统设置授权后，请重新打开屏幕词典。若开关已经打开，且这里仍显示未获准，请在系统设置移除同名旧条目，再添加当前应用包。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("刷新状态", action: refreshPermissions)
                        Button("重新打开屏幕词典", action: reopenApplication)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var language: some View {
        Form {
            Section("语言") {
                Picker("屏幕识别语言", selection: $preferences.config.sourceLanguage) {
                    Text(LanguageOption.automatic.title).tag(LanguageOption.automatic.id)
                    ForEach(LanguageOption.recognitionLanguages) { language in Text(language.title).tag(language.id) }
                }
                Picker("弹出词典译入语", selection: $preferences.config.dictionaryLanguage) {
                    ForEach(LanguageOption.targetLanguages) { language in Text(language.title).tag(language.id) }
                }
                Picker("屏幕翻译译入语", selection: $preferences.config.translationLanguage) {
                    ForEach(LanguageOption.targetLanguages) { language in Text(language.title).tag(language.id) }
                }
            }

            Section("弹出词典显示") {
                Toggle("显示上下文翻译", isOn: $preferences.config.showContext)
                Toggle("点击后显示上下文译文", isOn: $preferences.config.revealContext)
                    .disabled(!preferences.config.showContext)
                Toggle("显示语境释义", isOn: $preferences.config.showDefinition)
                Toggle("上下文翻译在上方", isOn: $preferences.config.contextFirst)
                    .disabled(!preferences.config.showContext || !preferences.config.showDefinition)
            }

            Section("翻译引擎") {
                Picker("配置模式", selection: $engineMode) {
                    ForEach(ScreenMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .onChange(of: engineMode) { _, _ in keyDraft = ""; keyStatus = "" }
                if #available(macOS 26, *) {
                    Picker("译文引擎", selection: textEngine) {
                        ForEach(TextTranslationEngine.allCases) { engine in Text(engine.title).tag(engine) }
                    }
                    if textEngine.wrappedValue == .apple {
                        Text("在系统设置的「通用 → 语言与地区 → 翻译语言」管理本机语言包。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if engineMode == .dictionary || textEngine.wrappedValue == .model {
                    modelSettings
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelSettings: some View {
        let onDemand = textEngine.wrappedValue == .apple
        Picker(onDemand ? "语境释义服务" : "模型服务", selection: engineKind) {
            ForEach(EngineKind.allCases) { kind in Text(kind.title).tag(kind) }
        }
        TextField("服务地址", text: engine.baseURL, prompt: Text(engine.wrappedValue.kind.exampleURL))
        TextField("模型名", text: engine.model)
        if engine.wrappedValue.kind == .compatible {
            SecureField("API 密钥", text: $keyDraft, prompt: Text("保存在钥匙串中"))
            HStack {
                Button("保存密钥") { saveKey(keyDraft) }.disabled(keyDraft.isEmpty)
                Button("清除已存密钥") { saveKey("") }
                if !keyStatus.isEmpty { Text(keyStatus).font(.callout).foregroundStyle(.secondary) }
            }
        }
        if onDemand {
            Text("词卡上的按钮会把本次查词所需的文字交给所选模型。")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text(engine.wrappedValue.kind == .ollama
                 ? "使用支持结构化 JSON 的 Ollama 模型。"
                 : "把本次识别到的文本送到所填服务，截图留在本机。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var apps: some View {
        Form {
            Section("画面行为") {
                Text("默认用触发时的截图定格画面。为指定应用启用「保持实时画面」，译文或词典会显示在透明覆盖层上。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("正在运行的应用", selection: $selectedApp) {
                        Text("选择应用…").tag("")
                        ForEach(runningApps) { app in Text(app.name).tag(app.id) }
                    }
                    Button("添加") {
                        guard let app = runningApps.first(where: { $0.id == selectedApp }) else { return }
                        preferences.setProfile(id: app.id, name: app.name, live: true)
                    }
                    .disabled(selectedApp.isEmpty)
                    Button(action: listApps) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新正在运行的应用")
                }
            }
            if !preferences.config.profiles.isEmpty {
                Section("独立设置") {
                    ForEach(preferences.config.profiles) { app in
                        HStack {
                            Toggle(app.name + " 保持实时画面", isOn: Binding {
                                preferences.config.profiles.first(where: { $0.id == app.id })?.liveBackground ?? false
                            } set: { live in
                                preferences.setProfile(id: app.id, name: app.name, live: live)
                            })
                            Spacer()
                            Button(role: .destructive) {
                                preferences.config.profiles.removeAll { $0.id == app.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("移除这条应用设置")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: listApps)
    }

    private var mouseStatus: String {
        switch preferences.mouseAccess {
        case .available: "鼠标监听可用"
        case .needsAuthorization: "当前进程未获准"
        case .listenerUnavailable: "鼠标监听暂不可用"
        }
    }

    private func permission(
        status: String, available: Bool, request: (() -> Void)?, openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Label(status, systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(available ? Color.green : Color.secondary)
            if let request { Button("申请授权…", action: request) }
            Button("系统设置…", action: openSettings)
        }
        .controlSize(.small)
    }

    private func mouseModifier(_ modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding {
            preferences.config.mouse.modifiers.contains(modifier)
        } set: { enabled in
            if enabled { preferences.config.mouse.modifiers.insert(modifier) }
            else { preferences.config.mouse.modifiers.remove(modifier) }
        }
    }

    private var engine: Binding<EngineSettings> {
        Binding {
            preferences.config.engine(for: engineMode)
        } set: { newValue in
            if engineMode == .dictionary { preferences.config.dictionaryEngine = newValue }
            else { preferences.config.screenEngine = newValue }
        }
    }

    private var textEngine: Binding<TextTranslationEngine> {
        Binding {
            preferences.config.textEngine(for: engineMode)
        } set: { value in
            if engineMode == .dictionary { preferences.config.dictionaryTextEngine = value }
            else { preferences.config.screenTextEngine = value }
        }
    }

    private var engineKind: Binding<EngineKind> {
        Binding {
            engine.wrappedValue.kind
        } set: { newKind in
            var newValue = engine.wrappedValue
            guard newValue.kind != newKind else { return }
            let oldDefault = newValue.kind.exampleURL
            if newValue.baseURL == oldDefault || newValue.baseURL.isEmpty {
                newValue.baseURL = newKind == .ollama ? newKind.exampleURL : ""
            }
            newValue.kind = newKind
            engine.wrappedValue = newValue
        }
    }

    private func saveKey(_ value: String) {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if EngineCredentials.save(token, for: engineMode) {
            keyStatus = token.isEmpty ? "已清除" : "已保存"
            keyDraft = ""
        } else {
            keyStatus = "钥匙串操作失败"
        }
    }

    private func listApps() {
        var ids = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(),
                  let id = app.bundleIdentifier, ids.insert(id).inserted else { return nil }
            return AppProfile(id: id, name: app.localizedName ?? id, liveBackground: false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !runningApps.contains(where: { $0.id == selectedApp }) { selectedApp = "" }
    }

    private func recordKey() {
        setRecording(true)
        keyHint = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                endRecording()
                return nil
            }
            let modifiers = ShortcutModifiers(flags: event.modifierFlags)
            let functionKey = Self.functionKeys[event.keyCode]
            guard !modifiers.isEmpty || functionKey != nil else {
                keyHint = "请选择修饰键组合，或使用 F1 至 F12。"
                return nil
            }
            let raw = event.charactersIgnoringModifiers ?? ""
            let name = functionKey ?? Self.namedKeys[event.keyCode] ?? (raw.isEmpty ? "\(event.keyCode)" : raw.uppercased())
            preferences.config.keyboard = KeyShortcut(code: UInt32(event.keyCode), name: name, modifiers: modifiers)
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyHint = nil
        setRecording(false)
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static let namedKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
