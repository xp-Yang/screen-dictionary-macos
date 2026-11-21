import AppKit
import SwiftUI

@MainActor
final class OverlayPanel: NSPanel {
    let surface: OverlaySurface
    var onDismiss: (() -> Void)?
    private var closingButton: Int?

    init(screen: NSScreen, image: CGImage, frozen: Bool, mode: ScreenMode) {
        surface = OverlaySurface(size: screen.frame.size, image: image, frozen: frozen, mode: mode)
        // The screen-taking initializer dispatches back to the four-argument initializer
        // on this subclass. Initialize the panel directly, then position it on the display.
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        canHide = false
        hidesOnDeactivate = false
        isOpaque = frozen
        hasShadow = false
        backgroundColor = frozen ? .black : NSColor.black.withAlphaComponent(0.012)
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle]
        contentView = surface
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !surface.isOverResult(event.locationInWindow) {
                closingButton = event.buttonNumber
                return
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if closingButton == event.buttonNumber { return }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if closingButton == event.buttonNumber {
                closingButton = nil
                onDismiss?()
                return
            }
        case .keyDown where event.keyCode == 53:
            onDismiss?()
            return
        case .scrollWheel where surface.mode == .translation:
            surface.zoomTranslations(event.scrollingDeltaY)
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
final class OverlaySurface: NSView {
    let mode: ScreenMode
    private let frameImage: NSImage?
    private let palette: FramePalette?
    private var wordRect: CGRect?
    private var progress: NSHostingView<OverlayNotice>?
    private var popup: NSHostingView<WordPopup>?
    private var popupID: UUID?
    private var popupRect: CGRect?
    private var tiles: [TranslationTile] = []
    private var sourceBlocks: [TextBlock] = []
    private var translations: [Int: String] = [:]
    private var zoom: CGFloat = 1

    init(size: CGSize, image: CGImage, frozen: Bool, mode: ScreenMode) {
        self.mode = mode
        frameImage = frozen ? NSImage(cgImage: image, size: size) : nil
        palette = mode == .translation ? FramePalette(image: image) : nil
        super.init(frame: CGRect(origin: .zero, size: size))
        autoresizingMask = [.width, .height]
        wantsLayer = true
    }

    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { frameImage != nil }

    override func draw(_ dirtyRect: NSRect) {
        frameImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        if let wordRect {
            let path = NSBezierPath(roundedRect: wordRect.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3)
            NSColor.systemYellow.withAlphaComponent(0.41).setFill()
            path.fill()
            NSColor.systemOrange.withAlphaComponent(0.86).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    func isOverResult(_ locationInWindow: CGPoint) -> Bool {
        let point = convert(locationInWindow, from: nil)
        return popupRect?.contains(point) == true || tiles.contains(where: { $0.frame.contains(point) })
    }

    func emphasize(_ rect: CGRect?) {
        if let wordRect { setNeedsDisplay(wordRect.insetBy(dx: -4, dy: -3)) }
        wordRect = rect.map(toView)
        if let wordRect { setNeedsDisplay(wordRect.insetBy(dx: -4, dy: -3)) }
    }

    func showNotice(_ message: String?, busy: Bool = false) {
        progress?.removeFromSuperview()
        progress = nil
        guard let message else { return }
        let view = NSHostingView(rootView: OverlayNotice(message: message, busy: busy))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 28,
                            width: size.width, height: size.height)
        addSubview(view, positioned: .above, relativeTo: nil)
        progress = view
    }

    func showWord(
        _ content: WordPopupContent, configuration: AppConfiguration,
        speak: @escaping () -> Void, askModel: @escaping () -> Void
    ) {
        showNotice(nil)
        let anchor = toView(content.target.word.rect)
        let margin: CGFloat = 12
        let width = min(424, bounds.width - margin * 2)
        let roomBelow = anchor.minY - margin
        let roomAbove = bounds.maxY - anchor.maxY - margin
        let contextHeight = configuration.showContext && content.contextTranslation != nil
            ? min(140, CGFloat(content.contextTranslation?.count ?? 0) * 0.53 + 58) : 0
        let meaningHeight: CGFloat = configuration.showDefinition && content.result != nil
            ? 255 : (content.offline != nil ? 205 : 145)
        let preferredHeight = meaningHeight + contextHeight + (content.modelActionTitle != nil ? 30 : 0)
        let below = roomBelow >= preferredHeight + 8 || roomBelow >= roomAbove
        let available = below ? roomBelow : roomAbove
        let height = min(max(available - 8, 100), preferredHeight, bounds.height - margin * 2)
        let x = min(max(anchor.midX - width * 0.32, margin), bounds.maxX - width - margin)
        let y = below ? anchor.minY - height - 8 : anchor.maxY + 8
        let frame = CGRect(x: x, y: min(max(y, margin), bounds.maxY - height - margin),
                           width: width, height: height).integral
        let root = WordPopup(content: content, configuration: configuration, speak: speak, askModel: askModel)
        if popupID == content.id, let popup {
            popup.rootView = root
            popup.frame = frame
        } else {
            popup?.removeFromSuperview()
            let view = NSHostingView(rootView: root)
            view.frame = frame
            addSubview(view, positioned: .above, relativeTo: nil)
            popup = view
            popupID = content.id
        }
        popupRect = frame
    }

    func showTranslations(_ translations: [Int: String], blocks: [TextBlock]) {
        self.translations = translations
        self.sourceBlocks = blocks
        redrawTranslations()
    }

    func zoomTranslations(_ amount: CGFloat) {
        guard !tiles.isEmpty, amount != 0 else { return }
        let newScale = min(max(zoom + (amount > 0 ? 0.08 : -0.08), 0.65), 1.8)
        guard newScale != zoom else { return }
        zoom = newScale
        redrawTranslations()
    }

    func scrollPopup(by amount: CGFloat) {
        guard let popup, let scroller = firstScrollView(in: popup),
              let document = scroller.documentView else { return }
        var origin = scroller.contentView.bounds.origin
        let direction: CGFloat = document.isFlipped ? -1 : 1
        origin.y += amount * direction
        scroller.contentView.scroll(to: scroller.contentView.constrainBoundsRect(
            CGRect(origin: origin, size: scroller.contentView.bounds.size)
        ).origin)
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func redrawTranslations() {
        guard let palette else { return }
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        let originalBoxes = sourceBlocks.map { (id: $0.id, rect: toView($0.rect)) }
        for block in sourceBlocks {
            guard let translated = translations[block.id],
                  translated.split(whereSeparator: \.isWhitespace) != block.text.split(whereSeparator: \.isWhitespace)
            else { continue }

            let original = toView(block.rect).insetBy(dx: -3, dy: -3).intersection(bounds)
            guard original.width > 0, original.height > 0 else { continue }
            let colors = palette.colors(near: block.rect)
            let neighbors = originalBoxes.filter { $0.id != block.id }.map(\.rect)
            let tile = TranslationTile(text: translated, ink: colors.ink, background: colors.background)
            tile.frame = tile.fit(
                to: original, within: bounds, neighbors: neighbors,
                textSize: (block.lines.first?.rect.height ?? block.rect.height) * bounds.height * 0.88,
                zoom: zoom
            )
            addSubview(tile, positioned: .below, relativeTo: progress)
            tiles.append(tile)
        }
    }

    private func toView(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
               width: rect.width * bounds.width, height: rect.height * bounds.height)
    }
}

private struct OverlayNotice: View {
    let message: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            Text(message).font(.callout).lineLimit(3).frame(maxWidth: 370, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.13)))
    }
}

struct WordPopupContent {
    enum Status {
        case ready
        case working(String)
        case note(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    let id = UUID()
    var target: WordTarget
    let offline: OfflineDefinition?
    var nativeTranslation: String?
    var result: WordMeaning?
    var status: Status
    var modelActionTitle: String?

    var contextTranslation: String? { nativeTranslation ?? result?.contextTranslation }
}

private struct WordPopup: View {
    let content: WordPopupContent
    let configuration: AppConfiguration
    let speak: () -> Void
    let askModel: () -> Void

    @State private var contextIsVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(content.target.word.text).font(.title2.weight(.semibold)).lineLimit(1).textSelection(.enabled)
                Spacer(minLength: 4)
                Button(action: speak) {
                    Image(systemName: "speaker.wave.2").imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("朗读单词")
                .accessibilityLabel("朗读单词")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if configuration.contextFirst { context }
                    if configuration.showDefinition {
                        if let result = content.result {
                            meaning(result)
                        } else if let offline = content.offline {
                            offlineMeaning(offline)
                        }
                    }
                    if !configuration.contextFirst { context }
                    switch content.status {
                    case .ready:
                        EmptyView()
                    case .note(let message):
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    case .working(let message):
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let title = content.modelActionTitle {
                        Button(title, action: askModel).buttonStyle(.bordered).controlSize(.small)
                    }
                    if content.contextTranslation != nil || content.result != nil || content.modelActionTitle != nil {
                        DisclosureGroup("原文上下文") {
                            Text(content.target.block.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.16)))
    }

    private func offlineMeaning(_ meaning: OfflineDefinition) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("离线词典").font(.caption.weight(.semibold))
                if let phonetic = meaning.phonetic { Text(phonetic).font(.callout).textSelection(.enabled) }
            }
            .foregroundStyle(.secondary)
            Text(meaning.translation).font(.body).lineLimit(4).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var context: some View {
        if configuration.showContext, let text = content.contextTranslation {
            VStack(alignment: .leading, spacing: 5) {
                Text("上下文翻译").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if configuration.revealContext && !contextIsVisible {
                    Button("显示译文") { contextIsVisible = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Text(highlighted(text)).font(.body).textSelection(.enabled)
                }
            }
        }
    }

    private func meaning(_ result: WordMeaning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("语境释义").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(result.translation).font(.headline).textSelection(.enabled)
            let metadata = [result.lemma == content.target.word.text ? nil : result.lemma,
                            result.pronunciation ?? content.offline?.phonetic, result.partOfSpeech, result.level]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !metadata.isEmpty {
                Text(metadata.joined(separator: "  ·  "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !result.definition.isEmpty {
                Text(result.definition).font(.body).textSelection(.enabled)
            }
            if let synonyms = result.synonyms, !synonyms.isEmpty {
                Label(synonyms.joined(separator: "、"), systemImage: "equal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let explanation = result.explanation, !explanation.isEmpty {
                DisclosureGroup("进一步解释") {
                    Text(explanation).font(.callout).textSelection(.enabled)
                }
                .font(.callout)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var styled = AttributedString(text)
        guard let result = content.result, let snippet = result.highlight, !snippet.isEmpty else { return styled }
        var searchStart = text.startIndex
        var match: Range<String.Index>?
        for _ in 0..<max(1, min(result.highlightOccurrence ?? 1, 24)) {
            guard let range = text.range(of: snippet, range: searchStart..<text.endIndex) else {
                return styled
            }
            match = range
            searchStart = range.upperBound
        }
        if let match, let range = Range(match, in: styled) {
            styled[range].backgroundColor = Color.yellow.opacity(0.5)
        }
        return styled
    }
}

private final class TranslationTile: NSView {
    private let text: String
    private let ink: NSColor
    private var fontSize: CGFloat = 15

    init(text: String, ink: NSColor, background: NSColor) {
        self.text = text
        self.ink = ink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
        toolTip = text
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        attributed(size: fontSize).draw(
            with: bounds.insetBy(dx: 4, dy: 2),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )
    }

    func fit(to original: CGRect, within screen: CGRect, neighbors: [CGRect],
             textSize: CGFloat, zoom: CGFloat) -> CGRect {
        let preferredSize = min(max(textSize, 11), 56) * zoom
        let safeWidth = max(original.width, 10)
        var rightLimit = screen.maxX
        var bottomLimit = screen.minY
        for neighbor in neighbors {
            if neighbor.minX >= original.maxX && neighbor.maxY > original.minY && neighbor.minY < original.maxY {
                rightLimit = min(rightLimit, neighbor.minX - 3)
            }
            if neighbor.maxY <= original.minY && neighbor.maxX > original.minX && neighbor.minX < original.maxX {
                bottomLimit = max(bottomLimit, neighbor.maxY + 3)
            }
        }
        let availableWidth = max(original.width, rightLimit - original.minX)
        let width = min(availableWidth, max(safeWidth, min(safeWidth + 150, attributed(size: preferredSize).size().width + 8)))
        let availableHeight = max(original.height, original.maxY - bottomLimit)
        fontSize = preferredSize
        var height = measuredHeight(width: width, size: fontSize)
        while height > availableHeight && fontSize > 8 {
            fontSize -= 0.75
            height = measuredHeight(width: width, size: fontSize)
        }
        let finalHeight = min(availableHeight, max(height, original.height))
        return CGRect(x: original.minX, y: original.maxY - finalHeight, width: width, height: finalHeight)
            .integral.intersection(screen)
    }

    private func measuredHeight(width: CGFloat, size: CGFloat) -> CGFloat {
        let size = attributed(size: size).boundingRect(
            with: CGSize(width: max(width - 8, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        return ceil(size.height) + 4
    }

    private func attributed(size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: ink,
            .paragraphStyle: paragraph
        ])
    }
}

private struct FramePalette {
    private let side = 64
    private let pixels: [UInt8]

    init(image: CGImage) {
        let length = side * side * 4
        var samples = [UInt8](repeating: 0, count: length)
        let sampleSide = side
        samples.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: sampleSide, height: sampleSide, bitsPerComponent: 8,
                bytesPerRow: sampleSide * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
        }
        pixels = samples
    }

    func colors(near box: CGRect) -> (background: NSColor, ink: NSColor) {
        let offset = 1.15 / CGFloat(side)
        var red: [UInt8] = [], green: [UInt8] = [], blue: [UInt8] = []
        for fraction in [0.15, 0.5, 0.85] {
            let x = box.minX + box.width * fraction
            let y = box.minY + box.height * fraction
            let points = [
                CGPoint(x: x, y: box.maxY + offset), CGPoint(x: x, y: box.minY - offset),
                CGPoint(x: box.minX - offset, y: y), CGPoint(x: box.maxX + offset, y: y)
            ]
            for point in points {
                let column = min(max(Int(point.x * CGFloat(side)), 0), side - 1)
                let row = min(max(Int((1 - point.y) * CGFloat(side)), 0), side - 1)
                let index = (row * side + column) * 4
                red.append(pixels[index])
                green.append(pixels[index + 1])
                blue.append(pixels[index + 2])
            }
        }
        func median(_ sample: [UInt8]) -> CGFloat { CGFloat(sample.sorted()[sample.count / 2]) / 255 }
        let r = median(red), g = median(green), b = median(blue)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (NSColor(srgbRed: r, green: g, blue: b, alpha: 1),
                luminance > 0.53 ? NSColor(white: 0.06, alpha: 1) : NSColor(white: 0.98, alpha: 1))
    }
}
