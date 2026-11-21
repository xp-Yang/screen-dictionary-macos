import AppKit
import Combine
import Security
import Vision

enum ScreenMode: String, Codable, CaseIterable, Identifiable {
    case dictionary
    case translation

    var id: Self { self }
    var title: String { self == .dictionary ? "弹出词典" : "屏幕翻译" }
    var icon: String { self == .dictionary ? "book.closed" : "character.bubble" }
}

struct LanguageOption: Identifiable {
    let id: String
    let title: String

    static let automatic = LanguageOption(id: "auto", title: "自动识别")
    static let common = [
        LanguageOption(id: "en-US", title: "英语"),
        LanguageOption(id: "zh-Hans", title: "简体中文"),
        LanguageOption(id: "zh-Hant", title: "繁体中文"),
        LanguageOption(id: "ja-JP", title: "日语"),
        LanguageOption(id: "ko-KR", title: "韩语"),
        LanguageOption(id: "fr-FR", title: "法语"),
        LanguageOption(id: "de-DE", title: "德语"),
        LanguageOption(id: "es-ES", title: "西班牙语"),
        LanguageOption(id: "it-IT", title: "意大利语"),
        LanguageOption(id: "pt-BR", title: "葡萄牙语"),
        LanguageOption(id: "ru-RU", title: "俄语"),
        LanguageOption(id: "uk-UA", title: "乌克兰语"),
        LanguageOption(id: "vi-VN", title: "越南语"),
        LanguageOption(id: "th-TH", title: "泰语"),
        LanguageOption(id: "ar-SA", title: "阿拉伯语")
    ]

    static let recognitionLanguages: [LanguageOption] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let supported = try? request.supportedRecognitionLanguages(), !supported.isEmpty else { return common }
        return supported.map(option).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    static let targetLanguages: [LanguageOption] = common + [
        "sq", "hy", "az", "be", "bs", "bg", "ca", "hr", "cs", "da", "nl", "et", "fi", "ka", "el",
        "he", "hi", "hu", "id", "kk", "lv", "lt", "mk", "ms", "mt", "mr", "nb", "fa", "pl",
        "ro", "sr-Latn", "sr-Cyrl", "sk", "sl", "sw", "sv", "tl", "ta", "te", "tr", "ur", "uz", "cy"
    ].map(option).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

    static func name(of code: String) -> String {
        code == automatic.id ? automatic.title : option(code).title
    }

    private static func option(_ code: String) -> LanguageOption {
        if let known = common.first(where: { $0.id == code }) { return known }
        let title = Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
        return LanguageOption(id: code, title: title)
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init(flags: NSEvent.ModifierFlags) {
        self.init(rawValue: 0)
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }

    var title: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }
            .map(\.1)
            .joined()
    }
}

struct KeyShortcut: Codable, Equatable {
    var code: UInt32
    var name: String
    var modifiers: ShortcutModifiers

    static let standard = KeyShortcut(code: 1, name: "S", modifiers: .option)
    var title: String { modifiers.title + name }
}

enum MouseButton: Int, Codable, CaseIterable, Identifiable {
    case left = 0
    case right
    case middle
    case back
    case forward

    var id: Self { self }
    var title: String {
        switch self {
        case .left: "左键"
        case .right: "右键"
        case .middle: "中键"
        case .back: "后退键"
        case .forward: "前进键"
        }
    }
}

struct MouseShortcut: Codable, Equatable {
    var enabled = true
    var modifiers: ShortcutModifiers = .option
    var button: MouseButton = .left

    var isUsable: Bool {
        enabled && (!modifiers.isEmpty || (button != .left && button != .right))
    }
}

enum ControllerButton: String, Codable, CaseIterable, Identifiable {
    case disabled, menu, options, leftShoulder, rightShoulder, leftStick, rightStick

    var id: Self { self }
    var title: String {
        switch self {
        case .disabled: "关闭"
        case .menu: "菜单／Start"
        case .options: "选项／Select"
        case .leftShoulder: "左肩键"
        case .rightShoulder: "右肩键"
        case .leftStick: "左摇杆按下"
        case .rightStick: "右摇杆按下"
        }
    }
}

enum EngineKind: String, Codable, CaseIterable, Identifiable {
    case ollama
    case compatible

    var id: Self { self }
    var title: String { self == .ollama ? "Ollama" : "OpenAI 兼容服务" }

    var exampleURL: String {
        self == .ollama ? "http://127.0.0.1:11434" : "https://服务地址/v1"
    }
}

enum TextTranslationEngine: String, Codable, CaseIterable, Identifiable {
    case apple
    case model

    var id: Self { self }
    var title: String { self == .apple ? "Apple 本机翻译" : "模型翻译" }
}

struct EngineSettings: Codable, Equatable {
    var kind: EngineKind = .ollama
    var baseURL = "http://127.0.0.1:11434"
    var model = "qwen3.5:4b-q4_K_M"
}

struct AppProfile: Codable, Identifiable {
    let id: String
    var name: String
    var liveBackground: Bool
}

struct AppConfiguration: Codable {
    var mode: ScreenMode = .dictionary
    var sourceLanguage = "en-US"
    var dictionaryLanguage = "zh-Hans"
    var translationLanguage = "zh-Hans"
    var keyboard = KeyShortcut.standard
    var mouse = MouseShortcut()
    var controller: ControllerButton = .disabled
    var dictionaryEngine = EngineSettings()
    var screenEngine = EngineSettings()
    var dictionaryTextEngine: TextTranslationEngine?
    var screenTextEngine: TextTranslationEngine?
    var showContext = true
    var revealContext = false
    var contextFirst = true
    var showDefinition = true
    var profiles: [AppProfile] = []
    var openedSettings = false

    func engine(for mode: ScreenMode) -> EngineSettings {
        mode == .dictionary ? dictionaryEngine : screenEngine
    }

    func textEngine(for mode: ScreenMode) -> TextTranslationEngine {
        guard #available(macOS 26, *) else { return .model }
        return (mode == .dictionary ? dictionaryTextEngine : screenTextEngine) ?? .apple
    }

    func targetLanguage(for mode: ScreenMode) -> String {
        mode == .dictionary ? dictionaryLanguage : translationLanguage
    }

    func freezesFrame(for appID: String?) -> Bool {
        profiles.first(where: { $0.id == appID })?.liveBackground != true
    }
}

enum MouseAccess {
    case needsAuthorization
    case listenerUnavailable
    case available
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    private let key = "configuration.v1"
    var onConfigurationChange: (() -> Void)?

    @Published var config: AppConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                defaults.set(data, forKey: key)
            }
            onConfigurationChange?()
        }
    }

    @Published var screenPermission = false
    @Published var mouseAccess: MouseAccess = .needsAuthorization
    @Published var keyboardIssue: String?

    init() {
        config = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(AppConfiguration.self, from: $0) }
            ?? AppConfiguration()
    }

    func setProfile(id: String, name: String, live: Bool) {
        if let index = config.profiles.firstIndex(where: { $0.id == id }) {
            config.profiles[index] = AppProfile(id: id, name: name, liveBackground: live)
        } else if live {
            config.profiles.append(AppProfile(id: id, name: name, liveBackground: true))
        }
    }
}

enum EngineCredentials {
    private static let service = "local.screendictionary.macos.translation"

    static func read(for mode: ScreenMode) -> String {
        var query = attributes(for: mode)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String, for mode: ScreenMode) -> Bool {
        let query = attributes(for: mode)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(token.utf8)
        let value = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var newItem = query
        newItem[kSecValueData as String] = data
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    private static func attributes(for mode: ScreenMode) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mode.rawValue
        ]
    }
}
