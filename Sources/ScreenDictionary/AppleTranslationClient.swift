import Foundation
import NaturalLanguage
import Translation

enum AppleTranslationProblem: LocalizedError {
    case unsupportedSystem
    case unknownSource
    case languageUnavailable(String, String)
    case languagesNotInstalled(String, String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "Apple 本机翻译需要 macOS 26 或更新版本。"
        case .unknownSource:
            return "无法判断原文的语言。请在设置里选择屏幕识别语言。"
        case .languageUnavailable(let source, let target):
            return "Apple 本机翻译未支持\(source)到\(target)。可以在设置里切换译文引擎。"
        case .languagesNotInstalled(let source, let target):
            return "请在系统设置的「通用 → 语言与地区 → 翻译语言」下载\(source)和\(target)。"
        case .emptyResult:
            return "Apple 本机翻译没有返回译文。"
        }
    }
}

@MainActor
final class AppleTranslationClient {
    private let sourceCode: String?
    private let targetCode: String
    private var session: TranslationSession?

    init(sourceLanguage: String, targetLanguage: String, sample: String) {
        sourceCode = sourceLanguage == "auto" ? NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue : sourceLanguage
        targetCode = targetLanguage
    }

    func translate(_ items: [(id: Int, text: String)]) async throws -> [Int: String] {
        guard #available(macOS 26, *) else { throw AppleTranslationProblem.unsupportedSystem }
        var translated: [Int: String] = [:]
        var requests: [TranslationSession.Request] = []
        for item in items {
            let text = item.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            if text.unicodeScalars.contains(where: CharacterSet.letters.contains) {
                requests.append(.init(sourceText: text, clientIdentifier: String(item.id)))
            } else {
                translated[item.id] = item.text
            }
        }
        guard !requests.isEmpty else { return translated }
        guard let sourceCode else { throw AppleTranslationProblem.unknownSource }
        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetCode)
        if source.minimalIdentifier == target.minimalIdentifier {
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text) })
        }

        let engine: TranslationSession
        if let session {
            engine = session
        } else {
            let sourceName = LanguageOption.name(of: sourceCode)
            let targetName = LanguageOption.name(of: targetCode)
            let status = await LanguageAvailability().status(from: source, to: target)
            try Task.checkCancellation()
            switch status {
            case .installed: break
            case .supported: throw AppleTranslationProblem.languagesNotInstalled(sourceName, targetName)
            default: throw AppleTranslationProblem.languageUnavailable(sourceName, targetName)
            }
            engine = TranslationSession(installedSource: source, target: target)
            session = engine
        }

        let responses = try await withTaskCancellationHandler {
            try await engine.translations(from: requests)
        } onCancel: {
            Task { @MainActor in engine.cancel() }
        }
        try Task.checkCancellation()
        for response in responses {
            guard let id = response.clientIdentifier.flatMap(Int.init),
                  !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            translated[id] = response.targetText
        }
        guard !translated.isEmpty else { throw AppleTranslationProblem.emptyResult }
        return translated
    }
}
