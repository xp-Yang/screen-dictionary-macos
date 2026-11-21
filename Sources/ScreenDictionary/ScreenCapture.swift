import AppKit
import NaturalLanguage
import ScreenCaptureKit
import Vision

enum CaptureProblem: LocalizedError {
    case permission
    case missingDisplay
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .permission: "请先允许屏幕录制，再触发查词。"
        case .missingDisplay: "当前显示器已断开，请在另一块屏幕上重试。"
        case .unsupportedLanguage(let language): "系统 OCR 不支持\(LanguageOption.name(of: language))，请切换识别语言。"
        }
    }
}

@MainActor
enum ScreenCapture {
    private static var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    private static var displayGeneration = 0

    static func displayLayoutChanged() {
        filters.removeAll()
        displayGeneration += 1
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(at point: CGPoint, controllerApp: NSRunningApplication? = nil) -> NSScreen? {
        if let app = controllerApp, let display = screenOfFrontWindow(pid: app.processIdentifier) {
            return display
        }
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    static func still(displayID: CGDirectDisplayID) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureProblem.permission }
        if let cached = filters[displayID] {
            do {
                return try await capture(using: cached)
            } catch {
                try Task.checkCancellation()
                if filters[displayID] === cached { filters.removeValue(forKey: displayID) }
            }
        }
        let generation = displayGeneration
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureProblem.missingDisplay
        }
        let ownApplication = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])
        // Only reuse a filter that will also hide our windows if they are opened later.
        if generation == displayGeneration, !ownApplication.isEmpty { filters[displayID] = filter }
        return try await capture(using: filter)
    }

    private static func capture(using filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func screenOfFrontWindow(pid: pid_t) -> NSScreen? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
              let mainScreen = NSScreen.screens.first else { return nil }
        for info in windows where (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let record = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: record as CFDictionary),
                  rect.width > 40, rect.height > 40 else { continue }
            let middle = CGPoint(x: rect.midX, y: mainScreen.frame.maxY - rect.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) {
                return screen
            }
        }
        return nil
    }
}

struct OCRWord {
    let text: String
    let range: NSRange
    let rect: CGRect
}

struct OCRLine {
    let text: String
    let rect: CGRect
    let words: [OCRWord]
    let vertical: Bool
}

struct TextBlock: Identifiable {
    let id: Int
    var lines: [OCRLine]

    var rect: CGRect { lines.reduce(.null) { $0.union($1.rect) } }
    var text: String { lines.map(\.text).joined(separator: "\n") }
}

struct WordTarget {
    let block: TextBlock
    let lineIndex: Int
    let word: OCRWord

    var markedContext: String {
        block.lines.enumerated().map { index, line in
            guard index == lineIndex, let range = Range(word.range, in: line.text) else { return line.text }
            return String(line.text[..<range.lowerBound])
                + "<selected>" + word.text + "</selected>"
                + String(line.text[range.upperBound...])
        }.joined(separator: "\n")
    }

    var sentence: String {
        let paragraph = block.lines.map(\.text).joined(separator: " ")
        let offset = block.lines.prefix(lineIndex).reduce(0) { $0 + $1.text.utf16.count + 1 }
        let range = NSRange(location: offset + word.range.location, length: word.range.length)
        guard let selection = Range(range, in: paragraph) else { return paragraph }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        let bounds = tokenizer.tokenRange(at: selection.lowerBound)
        guard bounds.lowerBound <= selection.lowerBound, bounds.upperBound >= selection.upperBound,
              !bounds.isEmpty else { return paragraph }
        return String(paragraph[bounds]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func touchesCropEdge(_ region: CGRect, screenSize: CGSize) -> Bool {
        let bounds = block.rect
        let horizontalMargin = 18 / max(screenSize.width, 1)
        let verticalMargin = max(18 / max(screenSize.height, 1), block.lines[lineIndex].rect.height * 1.7)
        return (region.minX > 0 && bounds.minX - region.minX < horizontalMargin)
            || (region.maxX < 1 && region.maxX - bounds.maxX < horizontalMargin)
            || (region.minY > 0 && bounds.minY - region.minY < verticalMargin)
            || (region.maxY < 1 && region.maxY - bounds.maxY < verticalMargin)
    }
}

struct OCRPage {
    let blocks: [TextBlock]

    var words: [WordTarget] {
        blocks.flatMap { block in
            block.lines.enumerated().flatMap { index, line in
                line.words.map { WordTarget(block: block, lineIndex: index, word: $0) }
            }
        }
    }

    func word(at point: CGPoint, screenSize: CGSize) -> WordTarget? {
        let slopX = 2 / max(screenSize.width, 1)
        let slopY = 2 / max(screenSize.height, 1)
        let candidates = words.filter { target in
            target.word.rect.insetBy(dx: -slopX, dy: -slopY).contains(point)
        }
        func distance(_ target: WordTarget) -> CGFloat {
            let rect = target.word.rect
            return hypot((rect.midX - point.x) * screenSize.width, (rect.midY - point.y) * screenSize.height)
        }
        return candidates.min { first, second in
            let firstContains = first.word.rect.contains(point)
            let secondContains = second.word.rect.contains(point)
            if firstContains != secondContains { return firstContains }
            return distance(first) < distance(second)
        }
    }

    func block(at point: CGPoint) -> TextBlock? {
        blocks.filter { $0.rect.contains(point) }.min {
            $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height
        }
    }
}

enum ScreenOCR {
    static func lookupRegion(at point: CGPoint, in screenSize: CGSize) -> CGRect? {
        let width = min(1, 1120 / max(screenSize.width, 1))
        let height = min(1, 232 / max(screenSize.height, 1))
        guard width < 1 || height < 1 else { return nil }
        return CGRect(x: min(max(point.x - width / 2, 0), 1 - width),
                      y: min(max(point.y - height / 2, 0), 1 - height), width: width, height: height)
    }

    static func read(
        _ image: CGImage, language: String, region: CGRect? = nil, includeWords: Bool = true
    ) async throws -> OCRPage {
        let worker = Task.detached(priority: .userInitiated) {
            try recognize(image, language: language, region: region, includeWords: includeWords)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func recognize(
        _ original: CGImage, language: String, region: CGRect?, includeWords: Bool
    ) throws -> OCRPage {
        try Task.checkCancellation()
        let crop = region.flatMap { croppedImage(original, region: $0) }
        let image = crop?.image ?? original
        func onDisplay(_ rect: CGRect) -> CGRect {
            guard let frame = crop?.frame else { return rect }
            return CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                          width: rect.width * frame.width, height: rect.height * frame.height)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = language == "auto"
        if language != "auto" {
            let supported = try request.supportedRecognitionLanguages()
            let prefix = language.split(separator: "-").first.map(String.init) ?? language
            let match = supported.first(where: { $0 == language })
                ?? supported.first(where: { $0 == prefix || $0.hasPrefix(prefix + "-") })
            guard let match else { throw CaptureProblem.unsupportedLanguage(language) }
            request.recognitionLanguages = [match]
        }

        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()

        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rect = observation.boundingBox
            let vertical = rect.height > rect.width * aspect * 1.5 && candidate.string.count > 1
            let words = includeWords ? tokens(in: candidate, rect: rect, language: language, vertical: vertical) : []
            let positioned = words.map { OCRWord(text: $0.text, range: $0.range, rect: onDisplay($0.rect)) }
            return OCRLine(text: candidate.string, rect: onDisplay(rect), words: positioned, vertical: vertical)
        }.sorted {
            if $0.rect.maxY == $1.rect.maxY { return $0.rect.minX < $1.rect.minX }
            return $0.rect.maxY > $1.rect.maxY
        }
        let screenAspect = CGFloat(original.width) / CGFloat(max(original.height, 1))
        return OCRPage(blocks: groupLines(lines, aspect: screenAspect))
    }

    private static func croppedImage(
        _ image: CGImage, region: CGRect
    ) -> (image: CGImage, frame: CGRect)? {
        let size = CGSize(width: image.width, height: image.height)
        // Display and Vision coordinates start at the bottom. CGImage crops start at the top.
        let pixels = CGRect(x: region.minX * size.width, y: (1 - region.maxY) * size.height,
                            width: region.width * size.width, height: region.height * size.height)
            .integral.intersection(CGRect(origin: .zero, size: size))
        guard !pixels.isEmpty, let image = image.cropping(to: pixels) else { return nil }
        let frame = CGRect(x: pixels.minX / size.width, y: 1 - pixels.maxY / size.height,
                           width: pixels.width / size.width, height: pixels.height / size.height)
        return (image, frame)
    }

    private static func tokens(
        in candidate: VNRecognizedText, rect: CGRect, language: String, vertical: Bool
    ) -> [OCRWord] {
        let string = candidate.string
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = string
        let baseLanguage = language.split(separator: "-").first.map(String.init) ?? language
        if language != "auto" {
            let code = ["zh-Hans", "zh-Hant"].contains(language) ? language : baseLanguage
            tokenizer.setLanguage(NLLanguage(rawValue: code))
        }
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
            if string[range].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                ranges.append(range)
            }
            return true
        }
        let rtl = ["ar", "he", "fa", "ur"].contains(baseLanguage)
        return ranges.map { range in
            let span = NSRange(range, in: string)
            let precise = (try? candidate.boundingBox(for: range))?.boundingBox
            let box: CGRect
            if let precise, !precise.isEmpty,
               ranges.count == 1 || (vertical ? precise.height < rect.height * 0.94 : precise.width < rect.width * 0.94) {
                box = precise
            } else {
                box = estimatedBox(rect, span: span, count: string.utf16.count, vertical: vertical, rtl: rtl)
            }
            return OCRWord(text: String(string[range]), range: span, rect: box)
        }
    }

    private static func estimatedBox(_ line: CGRect, span: NSRange, count: Int, vertical: Bool, rtl: Bool) -> CGRect {
        let length = CGFloat(max(count, 1))
        let start = CGFloat(span.location) / length
        let fraction = CGFloat(span.length) / length
        if vertical {
            return CGRect(x: line.minX, y: line.maxY - line.height * (start + fraction),
                          width: line.width, height: line.height * fraction)
        }
        let x = rtl ? line.maxX - line.width * (start + fraction) : line.minX + line.width * start
        return CGRect(x: x, y: line.minY, width: line.width * fraction, height: line.height)
    }

    private static func groupLines(_ lines: [OCRLine], aspect: CGFloat) -> [TextBlock] {
        var blocks: [TextBlock] = []
        for line in lines {
            let candidates = blocks.indices.compactMap { index -> (index: Int, gap: CGFloat)? in
                guard let above = blocks[index].lines.last,
                      let gap = continuationGap(above: above, below: line, aspect: aspect) else { return nil }
                return (index, gap)
            }
            if let closest = candidates.min(by: { $0.gap < $1.gap }) {
                blocks[closest.index].lines.append(line)
            } else {
                blocks.append(TextBlock(id: blocks.count + 1, lines: [line]))
            }
        }
        return blocks
    }

    private static func continuationGap(above: OCRLine, below: OCRLine, aspect: CGFloat) -> CGFloat? {
        let previous = above.rect
        let next = below.rect
        guard !above.vertical, !below.vertical else { return nil }
        let height = max(previous.height, next.height)
        let gap = previous.minY - next.maxY
        let minHeight = min(previous.height, next.height)
        guard minHeight > 0, minHeight / height > 0.61,
              gap >= -height * 0.18, gap <= height * 0.86 else { return nil }

        let overlap = min(previous.maxX, next.maxX) - max(previous.minX, next.minX)
        let indentation = abs(previous.minX - next.minX)
        guard overlap > min(previous.width, next.width) * 0.55,
              indentation * aspect <= height * 1.6,
              !startsListItem(below.text) else { return nil }
        return abs(gap) + indentation * aspect
    }

    private static func startsListItem(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespaces)
        return normalized.range(of: #"^([•●▪–-]\s*|\d+[.)、]\s+)"#, options: .regularExpression) != nil
    }
}
