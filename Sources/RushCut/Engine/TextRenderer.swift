import Foundation
import CoreGraphics
import CoreText

/// Dessine un texte (police, couleur, contour, ombre, fond) en image, à l'échelle du cadre.
/// La taille de police est une fraction de la hauteur du cadre : le rendu est identique quelle que soit la résolution.
enum TextRenderer {
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 200
        return c
    }()

    static func size(_ text: TextContent, canvas: CGSize) -> CGSize {
        guard let image = render(text, canvas: canvas) else { return CGSize(width: 1, height: 1) }
        return CGSize(width: image.width, height: image.height)
    }

    static func render(_ text: TextContent, canvas: CGSize, local: Double? = nil, clipDuration: Double = 0) -> CGImage? {
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        let reveal = local.flatMap { TextReveal.compute(text, local: $0, clipDuration: clipDuration) }
        let key = "\(text.hashValue)-\(reveal?.hashValue ?? 0)-\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let image = draw(text, canvas: canvas, reveal: reveal) else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }

    static func font(_ text: TextContent, pointSize: CGFloat) -> CTFont {
        var font = CTFontCreateWithName(text.fontName as CFString, pointSize, nil)
        var traits: CTFontSymbolicTraits = []
        if text.bold { traits.insert(.traitBold) }
        if text.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, pointSize, nil, traits, traits) {
            font = styled
        }
        return font
    }

    private static func attributed(_ text: TextContent, font: CTFont, fontPx: CGFloat, stroke: Bool, reveal: TextReveal?) -> NSAttributedString {
        var alignment: CTTextAlignment
        switch text.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        var spacing = CGFloat(text.lineSpacing) * fontPx
        let style: CTParagraphStyle = withUnsafePointer(to: &alignment) { alignPtr in
            withUnsafePointer(to: &spacing) { spacingPtr in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignPtr),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacingPtr),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTKernAttributeName as String): NSNumber(value: Double(text.letterSpacing) * Double(fontPx)),
        ]
        if stroke {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = CGColor(gray: 0, alpha: 0)
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = text.strokeColor.cgColor
            // Valeur positive = contour seul, en pourcentage de la taille de police.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = NSNumber(value: text.strokeWidth * 200)
        } else {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = text.color.cgColor
        }
        let string = reveal?.displayString ?? (text.string.isEmpty ? " " : text.string)
        let result = NSMutableAttributedString(string: string, attributes: attributes)
        guard let reveal else { return result }
        let length = (string as NSString).length
        let colorKey = NSAttributedString.Key(stroke ? kCTStrokeColorAttributeName as String : kCTForegroundColorAttributeName as String)
        let base = stroke ? text.strokeColor : text.color
        if let range = reveal.highlight, !stroke, NSMaxRange(range) <= length {
            result.addAttribute(colorKey, value: text.highlightColor.cgColor, range: range)
        }
        if let visible = reveal.visibleLength, visible < length {
            if let partial = reveal.partialAlpha, visible < length {
                result.addAttribute(colorKey, value: base.with(alpha: base.a * partial).cgColor, range: NSRange(location: visible, length: 1))
                let rest = visible + 1
                if rest < length {
                    result.addAttribute(colorKey, value: CGColor(gray: 0, alpha: 0), range: NSRange(location: rest, length: length - rest))
                }
            } else {
                result.addAttribute(colorKey, value: CGColor(gray: 0, alpha: 0), range: NSRange(location: visible, length: length - visible))
            }
        }
        return result
    }

    private static func draw(_ text: TextContent, canvas: CGSize, reveal: TextReveal?) -> CGImage? {
        let fontPx = max(4, CGFloat(text.fontSize) * canvas.height)
        let font = font(text, pointSize: fontPx)
        let fill = attributed(text, font: font, fontPx: fontPx, stroke: false, reveal: reveal)
        let framesetter = CTFramesetterCreateWithAttributedString(fill)
        let maxWidth = canvas.width * 0.92
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(min(maxWidth, suggested.width)) + 2, height: ceil(suggested.height) + 2)

        let padding = text.backgroundEnabled ? CGFloat(text.backgroundPadding) * fontPx : 0
        var margin: CGFloat = 2
        if text.strokeEnabled { margin = max(margin, CGFloat(text.strokeWidth) * fontPx) }
        if text.shadowEnabled {
            margin = max(margin, CGFloat(text.shadowBlur + abs(text.shadowOffset)) * fontPx * 1.5)
        }
        let width = Int(ceil(textSize.width + 2 * (padding + margin)))
        let height = Int(ceil(textSize.height + 2 * (padding + margin)))
        guard width > 0, height > 0, width < 16_384, height < 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)

        if text.backgroundEnabled {
            let rect = CGRect(x: margin, y: margin, width: CGFloat(width) - 2 * margin, height: CGFloat(height) - 2 * margin)
            let radius = min(CGFloat(text.backgroundCornerRadius) * fontPx, min(rect.width, rect.height) / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(text.backgroundColor.cgColor)
            ctx.fillPath()
        }

        let textRect = CGRect(x: margin + padding, y: margin + padding, width: textSize.width, height: textSize.height)
        let path = CGPath(rect: textRect, transform: nil)

        if text.shadowEnabled {
            let offset = CGFloat(text.shadowOffset) * fontPx
            ctx.setShadow(offset: CGSize(width: offset, height: -offset), blur: CGFloat(text.shadowBlur) * fontPx,
                          color: text.shadowColor.cgColor)
        }
        if text.strokeEnabled {
            let strokeString = attributed(text, font: font, fontPx: fontPx, stroke: true, reveal: reveal)
            let strokeSetter = CTFramesetterCreateWithAttributedString(strokeString)
            let strokeFrame = CTFramesetterCreateFrame(strokeSetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(strokeFrame, ctx)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }
}

/// État d'apparition d'un texte animé à un instant donné.
struct TextReveal: Hashable {
    /// Nombre de caractères (UTF-16) visibles ; nil = tout le texte.
    var visibleLength: Int? = nil
    /// Opacité du caractère en cours d'apparition.
    var partialAlpha: Double? = nil
    /// Plage mise en évidence (karaoké).
    var highlight: NSRange? = nil
    /// Texte remplacé (compteur).
    var displayString: String? = nil

    static func wordRanges(_ string: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    static func compute(_ text: TextContent, local: Double, clipDuration: Double) -> TextReveal? {
        guard let id = text.animation, let def = TextAnimationCatalog.byID[id] else {
            // Sous-titres minutés sans animation choisie : rien de particulier.
            return nil
        }
        let string = text.string
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let duration = max(0.1, text.animationDuration / def.speed)
        let progress = min(1, max(0, local / duration))
        let words = wordRanges(string)

        func wordIndexAt(_ t: Double) -> Int? {
            guard !words.isEmpty else { return nil }
            if !text.words.isEmpty {
                let seconds = text.words.map { ($0.start.seconds, $0.end.seconds) }
                for (i, w) in seconds.enumerated() where t >= w.0 && t < w.1 { return min(i, words.count - 1) }
                if let last = seconds.lastIndex(where: { t >= $0.0 }) { return min(last, words.count - 1) }
                return nil
            }
            let span = clipDuration > 0 ? clipDuration : duration
            return min(words.count - 1, Int(t / max(0.01, span) * Double(words.count)))
        }

        switch def.mode {
        case .typewriter:
            return progress >= 1 ? nil : TextReveal(visibleLength: Int(Double(length) * progress))
        case .cursor:
            let visible = Int(Double(length) * progress)
            let blinkOn = (local * 2).truncatingRemainder(dividingBy: 1) < 0.5
            let shown = String((string as NSString).substring(to: visible)) + (blinkOn ? "|" : " ")
            let rest = (string as NSString).substring(from: visible)
            return TextReveal(visibleLength: (shown as NSString).length, displayString: shown + rest)
        case .word, .wordPop:
            guard !words.isEmpty, progress < 1 else { return nil }
            let exact = progress * Double(words.count)
            let count = Int(exact)
            if count >= words.count { return nil }
            let end = count == 0 ? 0 : NSMaxRange(words[count - 1])
            if def.mode == .wordPop {
                let alpha = (exact - Double(count) * 4).rounded() / 4
                let next = words[count]
                return TextReveal(visibleLength: next.location, partialAlpha: nil).withPartial(end: end, alpha: alpha)
            }
            return TextReveal(visibleLength: end)
        case .letterFade:
            guard progress < 1 else { return nil }
            let exact = progress * Double(length)
            let alpha = ((exact - floor(exact)) * 4).rounded() / 4
            return TextReveal(visibleLength: Int(exact), partialAlpha: alpha)
        case .karaoke:
            guard let i = wordIndexAt(local) else { return nil }
            return TextReveal(highlight: words[i])
        case .karaokeFill:
            guard let i = wordIndexAt(local) else { return nil }
            return TextReveal(highlight: NSRange(location: 0, length: NSMaxRange(words[i])))
        case .counter:
            let digits = string.filter { $0.isNumber }
            guard let target = Double(digits) else { return nil }
            let value = Int((target * progress).rounded())
            guard let first = string.firstIndex(where: { $0.isNumber }),
                  let last = string.lastIndex(where: { $0.isNumber }) else { return nil }
            let shown = String(string[..<first]) + String(value) + String(string[string.index(after: last)...])
            return TextReveal(displayString: shown)
        }
    }

    /// Mot en cours d'apparition (opacité partielle sur son premier caractère).
    private func withPartial(end: Int, alpha: Double) -> TextReveal {
        var r = self
        r.visibleLength = end
        r.partialAlpha = nil
        _ = alpha
        return r
    }
}
