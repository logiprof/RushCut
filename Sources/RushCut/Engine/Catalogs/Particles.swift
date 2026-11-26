import Foundation
import CoreImage
import CoreGraphics

/// Particules dessinées image par image, de façon déterministe (même résultat à l'aperçu et à l'export).
enum Particles {
    enum Kind { case snow, rain, confetti, sparkle, heart, star, smoke, dust, bubble, firefly, petal, flake, note, bokeh, coin, firework }

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 90
        return c
    }()

    static let palette: [RGBA] = [
        RGBA(r: 1, g: 0.3, b: 0.35), RGBA(r: 1, g: 0.8, b: 0.2), RGBA(r: 0.3, g: 0.8, b: 1),
        RGBA(r: 0.5, g: 1, b: 0.5), RGBA(r: 0.85, g: 0.45, b: 1), RGBA(r: 1, g: 0.55, b: 0.2),
    ]

    static func overlay(_ i: CIImage, _ c: EffectContext, kind: Kind, count: Int, color: RGBA?) -> CIImage {
        let e = i.extent
        guard e.width >= 2, e.height >= 2, count > 0 else { return i }
        // Rendu à résolution réduite puis agrandi (rapide, invisible pour des particules).
        let scale = min(1, 720 / max(e.width, e.height))
        let w = max(2, Int(e.width * scale)), h = max(2, Int(e.height * scale))
        let key = "\(kind)-\(count)-\(color.map { "\($0.r)\($0.g)\($0.b)\($0.a)" } ?? "multi")-\(w)x\(h)-\(c.frame)" as NSString
        let image: CGImage
        if let cached = cache.object(forKey: key) {
            image = cached.image
        } else {
            guard let drawn = draw(kind: kind, count: count, color: color, width: w, height: h, time: c.local) else { return i }
            cache.setObject(Box(drawn), forKey: key)
            image = drawn
        }
        let layer = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(w), y: e.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        if kind == .bokeh || kind == .firefly || kind == .sparkle || kind == .firework {
            return layer.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: i]).cropped(to: e)
        }
        return layer.composited(over: i).cropped(to: e)
    }

    static func draw(kind: Kind, count: Int, color: RGBA?, width: Int, height: Int, time t: Double) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        let unit = min(W, H)
        ctx.setShouldAntialias(true)
        if kind == .firework {
            drawFireworks(ctx, W: W, H: H, t: t, count: count)
            return ctx.makeImage()
        }
        for n in 0..<count {
            let r1 = CI.random(n, 1), r2 = CI.random(n, 2), r3 = CI.random(n, 3), r4 = CI.random(n, 4)
            let c = color ?? palette[n % palette.count]
            var size = unit * CGFloat(0.008 + 0.02 * r3)
            var speed = 0.08 + 0.12 * r4     // fraction d'écran par seconde
            var x = r1, y = r2
            var angle = 0.0
            switch kind {
            case .snow, .flake, .dust, .petal, .confetti, .heart, .star, .note, .coin:
                if kind == .dust { speed *= 0.3; size *= 0.35 }
                if kind == .flake { size *= 2.2; speed *= 0.6 }
                if kind == .heart || kind == .star || kind == .note { size *= 2.4 }
                if kind == .coin { size *= 1.8; speed *= 2.2 }
                y = (r2 + t * speed).truncatingRemainder(dividingBy: 1.1)
                x = r1 + 0.03 * sin(t * (1 + r3 * 2) + Double(n))
                angle = t * (r3 - 0.5) * 6
            case .rain:
                speed = 1.4 + r4
                y = (r2 + t * speed).truncatingRemainder(dividingBy: 1.1)
                size = unit * 0.025 * CGFloat(0.6 + r3)
            case .bubble, .firefly, .smoke:
                speed = kind == .smoke ? 0.03 + 0.04 * r4 : 0.05 + 0.08 * r4
                y = 1 - (r2 + t * speed).truncatingRemainder(dividingBy: 1.1)
                x = r1 + 0.04 * sin(t * (0.6 + r3) + Double(n))
                if kind == .smoke { size = unit * CGFloat(0.15 + 0.2 * r3) }
                if kind == .bubble { size = unit * CGFloat(0.015 + 0.03 * r3) }
                if kind == .firefly { size = unit * CGFloat(0.006 + 0.006 * r3) }
            case .sparkle:
                let life = (t * (0.8 + r4) + r2 * 5).truncatingRemainder(dividingBy: 1)
                size = unit * CGFloat(0.02 * sin(life * .pi) * (0.5 + r3))
            case .bokeh:
                x = r1 + 0.02 * sin(t * 0.3 + Double(n))
                y = r2 + 0.02 * cos(t * 0.25 + Double(n))
                size = unit * CGFloat(0.03 + 0.07 * r3)
            case .firework:
                break
            }
            let px = CGFloat(x) * W
            let py = H - CGFloat(y - 0.05) * H
            ctx.saveGState()
            ctx.translateBy(x: px, y: py)
            ctx.rotate(by: CGFloat(angle))
            var alpha = c.a
            if kind == .firefly { alpha *= 0.5 + 0.5 * sin(t * 4 + Double(n)) }
            ctx.setFillColor(c.with(alpha: alpha).cgColor)
            ctx.setStrokeColor(c.with(alpha: alpha).cgColor)
            shape(kind, ctx: ctx, size: max(0.5, size))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private static func shape(_ kind: Kind, ctx: CGContext, size s: CGFloat) {
        switch kind {
        case .snow, .dust, .firefly, .bokeh, .smoke:
            ctx.fillEllipse(in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
        case .flake:
            ctx.setLineWidth(max(1, s * 0.08))
            for k in 0..<3 {
                ctx.saveGState()
                ctx.rotate(by: CGFloat(k) * .pi / 3)
                ctx.move(to: CGPoint(x: -s / 2, y: 0)); ctx.addLine(to: CGPoint(x: s / 2, y: 0))
                ctx.strokePath()
                ctx.restoreGState()
            }
        case .rain:
            ctx.setLineWidth(max(1, s * 0.06))
            ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: -s * 0.15, y: s))
            ctx.strokePath()
        case .confetti:
            ctx.fill(CGRect(x: -s / 2, y: -s / 4, width: s, height: s / 2))
        case .sparkle, .star:
            let path = CGMutablePath()
            let points = kind == .star ? 5 : 4
            for k in 0..<(points * 2) {
                let r = k % 2 == 0 ? s / 2 : s / (kind == .star ? 5 : 8)
                let a = CGFloat(k) * .pi / CGFloat(points) - .pi / 2
                let p = CGPoint(x: cos(a) * r, y: sin(a) * r)
                k == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
            ctx.addPath(path); ctx.fillPath()
        case .heart:
            ctx.addPath(StickerShapes.heart(in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s)))
            ctx.fillPath()
        case .bubble:
            ctx.setLineWidth(max(1, s * 0.08))
            ctx.strokeEllipse(in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
            ctx.fillEllipse(in: CGRect(x: -s * 0.25, y: s * 0.05, width: s * 0.18, height: s * 0.18))
        case .petal:
            ctx.fillEllipse(in: CGRect(x: -s / 2, y: -s / 4, width: s, height: s / 2))
        case .note:
            ctx.fillEllipse(in: CGRect(x: -s / 2, y: -s / 2, width: s * 0.55, height: s * 0.4))
            ctx.fill(CGRect(x: s * 0.0, y: -s * 0.35, width: s * 0.08, height: s * 0.9))
            ctx.fill(CGRect(x: s * 0.0, y: s * 0.45, width: s * 0.35, height: s * 0.1))
        case .coin:
            ctx.fillEllipse(in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
            ctx.setStrokeColor(CGColor(srgbRed: 0.8, green: 0.55, blue: 0.1, alpha: 1))
            ctx.setLineWidth(max(1, s * 0.1))
            ctx.strokeEllipse(in: CGRect(x: -s * 0.35, y: -s * 0.35, width: s * 0.7, height: s * 0.7))
        case .firework:
            break
        }
    }

    private static func drawFireworks(_ ctx: CGContext, W: CGFloat, H: CGFloat, t: Double, count: Int) {
        for b in 0..<max(1, count) {
            let cycle = 2.2
            let local = (t + Double(b) * 0.7).truncatingRemainder(dividingBy: cycle)
            let round = Int((t + Double(b) * 0.7) / cycle)
            let cx = W * CGFloat(0.15 + 0.7 * CI.random(b, round)), cy = H * CGFloat(0.5 + 0.35 * CI.random(b, round + 50))
            let color = palette[(b + round) % palette.count]
            let radius = min(W, H) * 0.25 * CGFloat(min(1, local / 0.8))
            let alpha = max(0, 1 - local / cycle)
            ctx.setStrokeColor(color.with(alpha: alpha).cgColor)
            ctx.setLineWidth(max(1, min(W, H) * 0.004))
            for k in 0..<24 {
                let a = CGFloat(k) / 24 * 2 * .pi
                ctx.move(to: CGPoint(x: cx + cos(a) * radius * 0.6, y: cy + sin(a) * radius * 0.6))
                ctx.addLine(to: CGPoint(x: cx + cos(a) * radius, y: cy + sin(a) * radius - CGFloat(local) * 10))
            }
            ctx.strokePath()
        }
    }
}
