import AppKit
import AVFoundation
import NaturalLanguage

@MainActor
final class OverlayCoordinator {
    private final class OverlaySession {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let origin: NSRunningApplication?
        let config: AppConfiguration
        lazy var client = TranslationClient(configuration: config, appName: origin?.localizedName ?? "")
        let trigger: TriggerSource
        let pointer: CGPoint

        var panel: OverlayPanel?
        var words: [WordTarget] = []
        var wordIndex: Int?
        var word: WordPopupContent?

        init(screen: NSScreen, displayID: CGDirectDisplayID, origin: NSRunningApplication?,
             config: AppConfiguration, trigger: TriggerSource, pointer: CGPoint) {
            self.screen = screen
            self.displayID = displayID
            self.origin = origin
            self.config = config
            self.trigger = trigger
            self.pointer = CGPoint(x: (pointer.x - screen.frame.minX) / screen.frame.width,
                                   y: (pointer.y - screen.frame.minY) / screen.frame.height)
        }
    }

    private let preferences: Preferences
    private let speaker = AVSpeechSynthesizer()
    private var active: OverlaySession?
    private var operation: Task<Void, Never>?
    private var lookup: Task<Void, Never>?
    var onIssue: ((String) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var isVisible: Bool { active?.panel != nil }

    func trigger(_ trigger: TriggerSource, at point: CGPoint) {
        guard CGPreflightScreenCaptureAccess() else {
            onIssue?(CaptureProblem.permission.localizedDescription)
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        let originatingApp = app?.processIdentifier == getpid() ? active?.origin : app
        dismiss(restoreFocus: false)
        guard let screen = ScreenCapture.screen(at: point, controllerApp: trigger == .controller ? originatingApp : nil),
              let displayID = ScreenCapture.displayID(of: screen) else {
            onIssue?(CaptureProblem.missingDisplay.localizedDescription)
            return
        }

        let session = OverlaySession(screen: screen, displayID: displayID, origin: originatingApp,
                                     config: preferences.config, trigger: trigger, pointer: point)
        active = session
        operation = Task { @MainActor [weak self] in await self?.present(session) }
    }

    func dismissFromOtherDisplay(_ point: CGPoint) -> (() -> Void)? {
        guard NSScreen.screens.count > 1, let session = active, session.panel != nil,
              !session.screen.frame.contains(point) else { return nil }
        return { [weak self, weak session] in
            guard let self, let session, self.active === session else { return }
            self.dismiss()
        }
    }

    func appActivated(_ app: NSRunningApplication) {
        guard let active, app.processIdentifier != getpid(),
              active.origin?.processIdentifier != app.processIdentifier else { return }
        dismiss(restoreFocus: false)
    }

    func dismiss(restoreFocus: Bool = true) {
        guard let session = active else { return }
        active = nil
        operation?.cancel()
        operation = nil
        lookup?.cancel()
        lookup = nil
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate) }
        session.panel?.orderOut(nil)
        session.panel = nil
        session.words.removeAll()
        session.word = nil
        if restoreFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
           let app = session.origin, !app.isTerminated {
            app.activate(options: [])
        }
    }

    func handleController(_ action: ControllerAction) {
        guard let session = active, let panel = session.panel,
              session.config.controller != .disabled else { return }
        switch action {
        case .close:
            dismiss()
        case .step(let delta):
            guard let current = session.wordIndex else { return }
            let next = min(max(current + delta, 0), session.words.count - 1)
            if next != current { selectWord(next, in: session, query: false) }
        case .confirm:
            if let word = session.word, word.modelActionTitle != nil {
                requestModel(for: word.id, in: session)
            } else if let index = session.wordIndex, session.word?.status.isWorking != true {
                selectWord(index, in: session, query: true)
            }
        case .speak:
            if let index = session.wordIndex, session.words.indices.contains(index) {
                speak(session.words[index], language: session.config.sourceLanguage)
            }
        case .scroll(let direction):
            if session.config.mode == .dictionary {
                panel.surface.scrollPopup(by: direction)
            } else {
                panel.surface.zoomTranslations(direction)
            }
        }
    }

    private func present(_ session: OverlaySession) async {
        do {
            let image = try await ScreenCapture.still(displayID: session.displayID)
            try Task.checkCancellation()
            guard active === session else { return }
            let config = session.config
            let isDictionary = config.mode == .dictionary
            let region = isDictionary && config.controller == .disabled
                ? ScreenOCR.lookupRegion(at: session.pointer, in: session.screen.frame.size) : nil
            async let reading = ScreenOCR.read(image, language: config.sourceLanguage,
                                              region: region, includeWords: isDictionary)
            let panel = OverlayPanel(screen: session.screen, image: image,
                                     frozen: config.freezesFrame(for: session.origin?.bundleIdentifier),
                                     mode: config.mode)
            panel.onDismiss = { [weak self] in self?.dismiss() }
            session.panel = panel
            panel.surface.showNotice("正在识别画面…", busy: true)
            panel.orderFrontRegardless()
            panel.makeKey()

            let page = try await reading
            try Task.checkCancellation()
            guard active === session else { return }
            if isDictionary {
                try await beginDictionary(page, image: image, region: region, session: session)
            } else if page.blocks.isEmpty {
                panel.surface.showNotice("画面中没有识别到文字")
            } else {
                await translate(page, session: session)
            }
        } catch is CancellationError {
            return
        } catch {
            guard active === session, !Task.isCancelled else { return }
            if let panel = session.panel {
                panel.surface.showNotice(error.localizedDescription)
            } else {
                active = nil
                onIssue?(error.localizedDescription)
            }
        }
    }

    private func beginDictionary(
        _ initialPage: OCRPage, image: CGImage, region: CGRect?, session: OverlaySession
    ) async throws {
        let screenSize = session.screen.frame.size
        var page = initialPage
        var sourceRegion = region
        var target = session.trigger == .controller
            ? page.words.first : page.word(at: session.pointer, screenSize: screenSize)
        if sourceRegion != nil, target == nil {
            page = try await ScreenOCR.read(image, language: session.config.sourceLanguage)
            try Task.checkCancellation()
            guard active === session else { return }
            sourceRegion = nil
            target = page.word(at: session.pointer, screenSize: screenSize)
        }

        session.words = page.words
        guard let target, let index = session.words.firstIndex(where: {
            $0.block.id == target.block.id && $0.lineIndex == target.lineIndex && $0.word.range == target.word.range
        }) else {
            session.panel?.surface.showNotice(page.blocks.isEmpty ? "画面中没有识别到文字"
                : "光标下没有识别到单词。指向文字后再次触发。")
            return
        }
        let contextMayBeClipped = sourceRegion.map {
            target.touchesCropEdge($0, screenSize: screenSize)
        } ?? false
        selectWord(index, in: session, query: true, expandContextFrom: contextMayBeClipped ? image : nil)
    }

    private func selectWord(
        _ index: Int, in session: OverlaySession, query: Bool, expandContextFrom image: CGImage? = nil
    ) {
        guard active === session, session.words.indices.contains(index),
              let surface = session.panel?.surface else { return }
        let target = session.words[index]
        lookup?.cancel()
        session.wordIndex = index
        let config = session.config
        let usesApple = config.textEngine(for: .dictionary) == .apple
        let offline = config.showDefinition ? OfflineDictionary.lookup(
            target.word.text, sourceLanguage: config.sourceLanguage, targetLanguage: config.dictionaryLanguage
        ) : nil
        let status: WordPopupContent.Status
        if query {
            status = .working(usesApple ? "正在查找本机译文…" : "正在理解上下文…")
        } else {
            status = .note("按 A 查询")
        }
        let word = WordPopupContent(target: target, offline: offline, status: status)
        session.word = word
        surface.emphasize(target.word.rect)
        renderWord(in: session)
        guard query else { return }

        lookup = Task { @MainActor [weak self] in
            await self?.loadWord(word.id, in: session, expandContextFrom: image)
        }
    }

    private func currentWord(_ id: UUID, in session: OverlaySession) -> WordPopupContent? {
        guard active === session, session.word?.id == id, !Task.isCancelled else { return nil }
        return session.word
    }

    private func renderWord(in session: OverlaySession) {
        guard let word = session.word, let surface = session.panel?.surface else { return }
        let language = session.config.sourceLanguage
        surface.showWord(word, configuration: session.config, speak: { [weak self] in
            self?.speak(word.target, language: language)
        }, askModel: { [weak self, weak session] in
            guard let session else { return }
            self?.requestModel(for: word.id, in: session)
        })
    }

    private func loadWord(_ id: UUID, in session: OverlaySession, expandContextFrom image: CGImage?) async {
        guard let word = currentWord(id, in: session) else { return }
        let config = session.config
        var target = word.target
        if let image, let fullPage = try? await ScreenOCR.read(image, language: config.sourceLanguage),
           let expanded = fullPage.word(at: session.pointer, screenSize: session.screen.frame.size),
           expanded.word.text == target.word.text {
            target = expanded
        }
        guard currentWord(id, in: session) != nil else { return }
        session.word?.target = target
        if config.textEngine(for: .dictionary) == .model {
            await fillWordFromModel(id, in: session)
            return
        }

        do {
            if config.showContext {
                let sentence = target.sentence
                let apple = AppleTranslationClient(sourceLanguage: config.sourceLanguage,
                                                   targetLanguage: config.dictionaryLanguage, sample: target.block.text)
                let response = try await apple.translate([(id: 0, text: sentence)])
                guard currentWord(id, in: session) != nil else { return }
                guard let text = response[0] else { throw AppleTranslationProblem.emptyResult }
                session.word?.nativeTranslation = text
            }
            session.word?.status = .ready
            if config.showDefinition || config.showContext {
                session.word?.modelActionTitle = config.showDefinition ? "查看语境释义" : "高亮译词"
            }
        } catch {
            guard currentWord(id, in: session) != nil else { return }
            session.word?.status = .note(error.localizedDescription)
            session.word?.modelActionTitle = "用模型翻译"
        }
        renderWord(in: session)
    }

    private func requestModel(for id: UUID, in session: OverlaySession) {
        guard currentWord(id, in: session)?.modelActionTitle != nil else { return }
        lookup?.cancel()
        session.word?.modelActionTitle = nil
        session.word?.status = .working("正在理解上下文…")
        renderWord(in: session)
        lookup = Task { @MainActor [weak self] in
            await self?.fillWordFromModel(id, in: session)
        }
    }

    private func fillWordFromModel(_ id: UUID, in session: OverlaySession) async {
        guard let word = currentWord(id, in: session) else { return }
        do {
            let answer = try await session.client.lookup(word.target, nativeTranslation: word.nativeTranslation)
            guard currentWord(id, in: session) != nil else { return }
            session.word?.result = answer
            session.word?.status = .ready
        } catch {
            guard currentWord(id, in: session) != nil else { return }
            session.word?.status = .note(error.localizedDescription)
            session.word?.modelActionTitle = "重试模型"
        }
        renderWord(in: session)
    }

    private func translate(_ page: OCRPage, session: OverlaySession) async {
        let hit = session.trigger == .controller ? nil : page.block(at: session.pointer)
        let targets = hit.map { [$0] } ?? page.blocks
        let batches = Self.batches(targets)
        let config = session.config
        let apple: AppleTranslationClient?
        if config.textEngine(for: .translation) == .apple {
            let sample = config.sourceLanguage == "auto"
                ? String(targets.lazy.map(\.text).joined(separator: "\n").prefix(2_400)) : ""
            apple = AppleTranslationClient(sourceLanguage: config.sourceLanguage,
                                           targetLanguage: config.translationLanguage, sample: sample)
        } else {
            apple = nil
        }
        var translated: [Int: String] = [:]
        do {
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                guard active === session, let surface = session.panel?.surface else { return }
                let detail = batches.count == 1 ? "" : " \(index + 1)/\(batches.count)"
                let prefix = apple == nil ? "正在翻译" : "正在本机翻译"
                surface.showNotice("\(prefix)\(hit == nil ? "整屏" : "当前段落")\(detail)…", busy: true)
                if let apple {
                    let response = try await apple.translate(batch.map { (id: $0.id, text: $0.text) })
                    translated.merge(response, uniquingKeysWith: { current, _ in current })
                } else {
                    let first = batch[0].id
                    let last = batch[batch.count - 1].id
                    let neighbors = page.blocks.filter {
                        (first - 2..<first).contains($0.id) || (last + 1...last + 2).contains($0.id)
                    }
                    let response = try await session.client.translate(batch, reference: neighbors)
                    try Task.checkCancellation()
                    translated.merge(response, uniquingKeysWith: { current, _ in current })
                    let missing = batch.filter { translated[$0.id] == nil }
                    if !missing.isEmpty {
                        let retry = try await session.client.translate(missing, reference: neighbors)
                        translated.merge(retry, uniquingKeysWith: { current, _ in current })
                    }
                }
                try Task.checkCancellation()
                guard active === session else { return }
                surface.showTranslations(translated, blocks: page.blocks)
            }
            guard active === session, let surface = session.panel?.surface else { return }
            if translated.count < targets.count {
                surface.showNotice("部分文字没有返回译文")
            } else if targets.allSatisfy({ block in
                translated[block.id]?.split(whereSeparator: \.isWhitespace) == block.text.split(whereSeparator: \.isWhitespace)
            }) {
                surface.showNotice("没有需要替换的文字")
            } else {
                surface.showNotice(nil)
            }
        } catch is CancellationError {
            return
        } catch {
            guard active === session, let surface = session.panel?.surface else { return }
            surface.showTranslations(translated, blocks: page.blocks)
            surface.showNotice(error.localizedDescription)
        }
    }

    private static func batches(_ blocks: [TextBlock]) -> [[TextBlock]] {
        var batches: [[TextBlock]] = []
        var batch: [TextBlock] = []
        var characters = 0
        for block in blocks {
            let length = block.text.count
            if !batch.isEmpty && (batch.count >= 6 || characters + length > 2_100) {
                batches.append(batch)
                batch = []
                characters = 0
            }
            batch.append(block)
            characters += length
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private func speak(_ target: WordTarget, language: String) {
        speaker.stopSpeaking(at: .immediate)
        let code: String
        switch language {
        case "auto": code = NLLanguageRecognizer.dominantLanguage(for: target.block.text)?.rawValue ?? "en-US"
        case "zh-Hans": code = "zh-CN"
        case "zh-Hant": code = "zh-TW"
        default: code = language
        }
        let utterance = AVSpeechUtterance(string: target.word.text)
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        speaker.speak(utterance)
    }
}
