import Foundation
import CoreGraphics
import CoreText

/// Formes vectorielles réutilisables.
enum StickerShapes {
    static func heart(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.midX, y: r.minY + h * 0.18))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.minX - w * 0.1, y: r.minY - h * 0.1), control2: CGPoint(x: r.minX, y: r.minY + h * 0.75))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY + h * 0.18), control1: CGPoint(x: r.maxX, y: r.minY + h * 0.75), control2: CGPoint(x: r.maxX + w * 0.1, y: r.minY - h * 0.1))
        return p
    }

    static func star(in r: CGRect, points: Int = 5, inner: CGFloat = 0.45) -> CGPath {
        let p = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        for k in 0..<(points * 2) {
            let radius = k % 2 == 0 ? R : R * inner
            let a = CGFloat(k) * .pi / CGFloat(points) - .pi / 2
            let pt = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
            k == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }

    /// Flèche pointant vers la droite.
    static func arrow(in r: CGRect, headRatio: CGFloat = 0.38, shaft: CGFloat = 0.32) -> CGPath {
        let p = CGMutablePath()
        let head = r.width * headRatio, sh = r.height * shaft / 2
        p.move(to: CGPoint(x: r.minX, y: r.midY - sh))
        p.addLine(to: CGPoint(x: r.maxX - head, y: r.midY - sh))
        p.addLine(to: CGPoint(x: r.maxX - head, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - head, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - head, y: r.midY + sh))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY + sh))
        p.closeSubpath()
        return p
    }
}

struct StickerDef: Identifiable {
    let id: String
    let name: String
    let category: String
    /// Proportions largeur / hauteur.
    let aspect: CGFloat
    /// Dessin dans un rectangle (origine en haut à gauche), avec la couleur choisie.
    let draw: (CGContext, CGRect, CGColor) -> Void
}

/// 50 autocollants originaux dessinés en vectoriel (flèches, cercles, bulles, numéros…).
enum StickerCatalog {
    static let all: [StickerDef] = build()
    static let byID: [String: StickerDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static var categories: [String] { var seen: [String] = []; for s in all where !seen.contains(s.category) { seen.append(s.category) }; return seen }

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 120; return c }()

    /// Image de l'autocollant, haute d'environ un quart du cadre.
    static func render(_ id: String, color: RGBA, canvas: CGSize) -> CGImage? {
        guard let def = byID[id] else { return nil }
        let h = max(16, Int(canvas.height * 0.25)), w = max(16, Int(CGFloat(h) * def.aspect))
        let key = "\(id)-\(color.r)-\(color.g)-\(color.b)-\(color.a)-\(w)x\(h)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        let inset = CGFloat(h) * 0.06
        def.draw(ctx, CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: inset, dy: inset), color.cgColor)
        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }

    private static func label(_ ctx: CGContext, _ text: String, in r: CGRect, color: CGColor, bold: Bool = true) {
        let size = r.height * 0.55
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: r.midX - bounds.width / 2 - bounds.minX, y: r.midY + bounds.height / 2 + bounds.minY)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func build() -> [StickerDef] {
        var list: [StickerDef] = []
        func add(_ id: String, _ name: String, _ cat: String, aspect: CGFloat = 1, _ f: @escaping (CGContext, CGRect, CGColor) -> Void) {
            list.append(StickerDef(id: id, name: name, category: cat, aspect: aspect, draw: f))
        }
        // Flèches (10)
        let directions: [(String, String, CGFloat)] = [("droite", "Flèche droite", 0), ("gauche", "Flèche gauche", .pi), ("haut", "Flèche haut", -.pi / 2),
                                                       ("bas", "Flèche bas", .pi / 2), ("diag-haut", "Flèche diagonale haut", -.pi / 4), ("diag-bas", "Flèche diagonale bas", .pi / 4)]
        for (id, name, angle) in directions {
            add("fleche-\(id)", name, "Flèches") { ctx, r, color in
                ctx.saveGState()
                ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: angle)
                let s = min(r.width, r.height)
                ctx.addPath(StickerShapes.arrow(in: CGRect(x: -s / 2, y: -s / 4, width: s, height: s / 2)))
                ctx.setFillColor(color); ctx.fillPath()
                ctx.restoreGState()
            }
        }
        add("fleche-courbe", "Flèche courbe", "Flèches") { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.09); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: r.minX, y: r.maxY * 0.8)); ctx.addQuadCurve(to: CGPoint(x: r.maxX * 0.82, y: r.minY + r.height * 0.3), control: CGPoint(x: r.minX + r.width * 0.2, y: r.minY))
            ctx.strokePath()
            ctx.addPath(StickerShapes.arrow(in: CGRect(x: r.maxX * 0.7, y: r.minY + r.height * 0.15, width: r.width * 0.3, height: r.height * 0.3), headRatio: 1, shaft: 1))
            ctx.setFillColor(color); ctx.fillPath()
        }
        add("fleche-fine", "Flèche fine", "Flèches", aspect: 2) { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.08); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: r.minX, y: r.midY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            ctx.move(to: CGPoint(x: r.maxX - r.height * 0.35, y: r.midY - r.height * 0.3)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            ctx.addLine(to: CGPoint(x: r.maxX - r.height * 0.35, y: r.midY + r.height * 0.3)); ctx.strokePath()
        }
        add("fleche-double", "Double flèche", "Flèches", aspect: 2) { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.08); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: r.minX, y: r.midY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            for (x, d) in [(r.maxX, CGFloat(-1)), (r.minX, CGFloat(1))] {
                ctx.move(to: CGPoint(x: x + d * r.height * 0.35, y: r.midY - r.height * 0.3)); ctx.addLine(to: CGPoint(x: x, y: r.midY))
                ctx.addLine(to: CGPoint(x: x + d * r.height * 0.35, y: r.midY + r.height * 0.3))
            }
            ctx.strokePath()
        }
        add("fleche-ronde", "Flèche dans un rond", "Flèches") { ctx, r, color in
            ctx.setFillColor(color); ctx.fillEllipse(in: r)
            ctx.addPath(StickerShapes.arrow(in: r.insetBy(dx: r.width * 0.22, dy: r.height * 0.3)))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        }
        // Mise en évidence (10)
        add("cercle", "Cercle", "Mise en évidence") { ctx, r, color in ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.06); ctx.strokeEllipse(in: r.insetBy(dx: r.height * 0.04, dy: r.height * 0.04)) }
        add("cercle-main", "Cercle à main levée", "Mise en évidence", aspect: 1.5) { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.06); ctx.setLineCap(.round)
            let c = CGPoint(x: r.midX, y: r.midY)
            for k in 0...40 {
                let a = CGFloat(k) / 36 * 2 * .pi
                let rx = r.width * (0.46 + 0.02 * sin(a * 3)), ry = r.height * (0.42 + 0.03 * cos(a * 2))
                let p = CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
                k == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
            }
            ctx.strokePath()
        }
        add("rectangle", "Rectangle", "Mise en évidence", aspect: 1.6) { ctx, r, color in ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.06); ctx.stroke(r.insetBy(dx: r.height * 0.04, dy: r.height * 0.04)) }
        add("rectangle-arrondi", "Rectangle arrondi", "Mise en évidence", aspect: 1.6) { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.06)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: r.height * 0.05, dy: r.height * 0.05), cornerWidth: r.height * 0.18, cornerHeight: r.height * 0.18, transform: nil)); ctx.strokePath()
        }
        add("soulignement", "Soulignement", "Mise en évidence", aspect: 4) { ctx, r, color in
            ctx.setFillColor(color); ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.midY - r.height * 0.12, width: r.width, height: r.height * 0.24), cornerWidth: r.height * 0.12, cornerHeight: r.height * 0.12, transform: nil)); ctx.fillPath()
        }
        add("soulignement-vague", "Soulignement ondulé", "Mise en évidence", aspect: 4) { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.15); ctx.setLineCap(.round)
            for k in 0...60 {
                let x = r.minX + r.width * CGFloat(k) / 60
                let y = r.midY + sin(CGFloat(k) / 60 * 6 * .pi) * r.height * 0.2
                k == 0 ? ctx.move(to: CGPoint(x: x, y: y)) : ctx.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.strokePath()
        }
        add("surligneur", "Surligneur", "Mise en évidence", aspect: 3) { ctx, r, color in
            ctx.setFillColor(color.copy(alpha: 0.45) ?? color); ctx.fill(r.insetBy(dx: 0, dy: r.height * 0.15))
        }
        add("coche", "Coche", "Mise en évidence") { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.14); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: r.minX + r.width * 0.1, y: r.midY)); ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.4, y: r.maxY - r.height * 0.15))
            ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY + r.height * 0.15)); ctx.strokePath()
        }
        add("croix", "Croix", "Mise en évidence") { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.14); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: r.minX + r.width * 0.15, y: r.minY + r.height * 0.15)); ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.15, y: r.maxY - r.height * 0.15))
            ctx.move(to: CGPoint(x: r.maxX - r.width * 0.15, y: r.minY + r.height * 0.15)); ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.15, y: r.maxY - r.height * 0.15)); ctx.strokePath()
        }
        add("exclamation", "Point d'exclamation", "Mise en évidence") { ctx, r, color in
            ctx.setFillColor(color); ctx.fillEllipse(in: r)
            label(ctx, "!", in: r, color: CGColor(gray: 1, alpha: 1))
        }
        // Bulles (6)
        let bubbles: [(String, String, Bool)] = [("bulle", "Bulle de dialogue", false), ("bulle-pensee", "Bulle de pensée", true)]
        for (id, name, thought) in bubbles {
            add(id, name, "Bulles", aspect: 1.5) { ctx, r, color in
                ctx.setFillColor(color)
                let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.75)
                if thought {
                    ctx.fillEllipse(in: body)
                    ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.15, y: r.maxY - r.height * 0.22, width: r.height * 0.16, height: r.height * 0.12))
                    ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.06, y: r.maxY - r.height * 0.08, width: r.height * 0.09, height: r.height * 0.07))
                } else {
                    ctx.addPath(CGPath(roundedRect: body, cornerWidth: r.height * 0.2, cornerHeight: r.height * 0.2, transform: nil)); ctx.fillPath()
                    ctx.move(to: CGPoint(x: r.minX + r.width * 0.2, y: body.maxY - 1)); ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.12, y: r.maxY))
                    ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: body.maxY - 1)); ctx.fillPath()
                }
            }
        }
        add("bulle-cri", "Bulle de cri", "Bulles", aspect: 1.3) { ctx, r, color in
            ctx.addPath(StickerShapes.star(in: r, points: 14, inner: 0.78)); ctx.setFillColor(color); ctx.fillPath()
        }
        add("bulle-info", "Bulle d'information", "Bulles", aspect: 1.5) { ctx, r, color in
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.8), cornerWidth: r.height * 0.08, cornerHeight: r.height * 0.08, transform: nil)); ctx.fillPath()
            ctx.move(to: CGPoint(x: r.midX - r.height * 0.12, y: r.minY + r.height * 0.8 - 1)); ctx.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            ctx.addLine(to: CGPoint(x: r.midX + r.height * 0.12, y: r.minY + r.height * 0.8 - 1)); ctx.fillPath()
            label(ctx, "i", in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.8), color: CGColor(gray: 0.08, alpha: 1))
        }
        let tags: [(String, String)] = [("nouveau", "NOUVEAU"), ("important", "IMPORTANT"), ("a-retenir", "À RETENIR"), ("astuce", "ASTUCE"), ("attention", "ATTENTION"), ("bravo", "BRAVO !")]
        for (id, text) in tags {
            add("badge-\(id)", "Étiquette « \(text.capitalized) »", "Étiquettes", aspect: 3) { ctx, r, color in
                ctx.setFillColor(color)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height * 0.3, cornerHeight: r.height * 0.3, transform: nil)); ctx.fillPath()
                label(ctx, text, in: r.insetBy(dx: r.height * 0.2, dy: r.height * 0.12), color: CGColor(gray: 0.08, alpha: 1))
            }
        }
        // Numéros d'étape (10)
        for n in 1...10 {
            add("etape-\(n)", "Étape \(n)", "Numéros d'étape") { ctx, r, color in
                ctx.setFillColor(color); ctx.fillEllipse(in: r)
                label(ctx, "\(n)", in: r.insetBy(dx: r.width * 0.15, dy: r.height * 0.18), color: CGColor(gray: 0.08, alpha: 1))
            }
        }
        // Formes et icônes (10)
        add("etoile", "Étoile", "Formes") { ctx, r, color in ctx.addPath(StickerShapes.star(in: r)); ctx.setFillColor(color); ctx.fillPath() }
        add("coeur", "Cœur", "Formes") { ctx, r, color in ctx.addPath(StickerShapes.heart(in: r)); ctx.setFillColor(color); ctx.fillPath() }
        add("eclair", "Éclair", "Formes", aspect: 0.7) { ctx, r, color in
            let pts = [(0.6, 0.0), (0.1, 0.55), (0.45, 0.55), (0.3, 1.0), (0.9, 0.4), (0.55, 0.4), (0.75, 0.0)]
            for (k, p) in pts.enumerated() {
                let pt = CGPoint(x: r.minX + r.width * p.0, y: r.minY + r.height * p.1)
                k == 0 ? ctx.move(to: pt) : ctx.addLine(to: pt)
            }
            ctx.closePath(); ctx.setFillColor(color); ctx.fillPath()
        }
        add("eclat", "Éclat", "Formes") { ctx, r, color in ctx.addPath(StickerShapes.star(in: r, points: 12, inner: 0.7)); ctx.setFillColor(color); ctx.fillPath() }
        add("cible", "Cible", "Formes") { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.07)
            for f in [0.0, 0.18, 0.34] { ctx.strokeEllipse(in: r.insetBy(dx: r.width * f, dy: r.height * f)) }
            ctx.setFillColor(color); ctx.fillEllipse(in: r.insetBy(dx: r.width * 0.44, dy: r.height * 0.44))
        }
        add("clic", "Clic de souris", "Formes") { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.height * 0.05)
            ctx.strokeEllipse(in: r.insetBy(dx: r.width * 0.05, dy: r.height * 0.05))
            ctx.setFillColor(color.copy(alpha: 0.5) ?? color); ctx.fillEllipse(in: r.insetBy(dx: r.width * 0.3, dy: r.height * 0.3))
        }
        add("curseur", "Curseur", "Formes", aspect: 0.75) { ctx, r, color in
            let pts = [(0.0, 0.0), (0.0, 0.85), (0.25, 0.65), (0.42, 1.0), (0.58, 0.93), (0.42, 0.6), (0.75, 0.6)]
            for (k, p) in pts.enumerated() {
                let pt = CGPoint(x: r.minX + r.width * p.0, y: r.minY + r.height * p.1)
                k == 0 ? ctx.move(to: pt) : ctx.addLine(to: pt)
            }
            ctx.closePath(); ctx.setFillColor(color); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(r.height * 0.03)
            ctx.drawPath(using: .fillStroke)
        }
        add("pouce", "Pouce levé", "Formes") { ctx, r, color in
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.42, width: r.width * 0.6, height: r.height * 0.5), cornerWidth: r.width * 0.1, cornerHeight: r.width * 0.1, transform: nil))
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.05, width: r.width * 0.2, height: r.height * 0.5), cornerWidth: r.width * 0.1, cornerHeight: r.width * 0.1, transform: nil))
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + r.width * 0.08, y: r.minY + r.height * 0.45, width: r.width * 0.17, height: r.height * 0.47), cornerWidth: r.width * 0.05, cornerHeight: r.width * 0.05, transform: nil))
            ctx.fillPath()
        }
        add("ampoule", "Idée", "Formes", aspect: 0.75) { ctx, r, color in
            ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.width))
            ctx.fill(CGRect(x: r.minX + r.width * 0.3, y: r.minY + r.width * 0.85, width: r.width * 0.4, height: r.height - r.width * 0.85))
        }
        add("cadenas", "Cadenas", "Formes", aspect: 0.8) { ctx, r, color in
            ctx.setStrokeColor(color); ctx.setLineWidth(r.width * 0.12)
            ctx.addArc(center: CGPoint(x: r.midX, y: r.minY + r.height * 0.4), radius: r.width * 0.3, startAngle: .pi, endAngle: 0, clockwise: false); ctx.strokePath()
            ctx.setFillColor(color); ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY + r.height * 0.4, width: r.width, height: r.height * 0.6), cornerWidth: r.width * 0.08, cornerHeight: r.width * 0.08, transform: nil)); ctx.fillPath()
        }
        return list
    }
}
