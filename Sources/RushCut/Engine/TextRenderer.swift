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

    static func render(_ text: TextContent, canvas: CGSize) -> CGImage? {
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        let key = "\(text.hashValue)-\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let image = draw(text, canvas: canvas) else { return nil }
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

    private static func attributed(_ text: TextContent, font: CTFont, fontPx: CGFloat, stroke: Bool) -> NSAttributedString {
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
        let string = text.string.isEmpty ? " " : text.string
        return NSAttributedString(string: string, attributes: attributes)
    }

    private static func draw(_ text: TextContent, canvas: CGSize) -> CGImage? {
        let fontPx = max(4, CGFloat(text.fontSize) * canvas.height)
        let font = font(text, pointSize: fontPx)
        let fill = attributed(text, font: font, fontPx: fontPx, stroke: false)
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
            let strokeString = attributed(text, font: font, fontPx: fontPx, stroke: true)
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
