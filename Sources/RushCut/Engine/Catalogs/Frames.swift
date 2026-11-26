import Foundation
import CoreImage
import CoreGraphics

/// Cadres et écrans : l'image est réduite dans une zone, puis un habillage est dessiné par-dessus.
struct FrameDef {
    let id: String
    let name: String
    /// Zone de l'image, en fractions (origine en haut à gauche).
    let content: CGRect
    let background: RGBA
    /// Coins arrondis de la zone, en fraction du plus petit côté.
    let cornerRadius: CGFloat
    let ellipse: Bool
    let draw: (CGContext, CGSize, CGRect) -> Void
}

enum Frames {
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()

    static let all: [FrameDef] = [
        FrameDef(id: "fine", name: "Bordure fine", content: CGRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94), background: .white, cornerRadius: 0, ellipse: false) { _, _, _ in },
        FrameDef(id: "epaisse", name: "Bordure épaisse", content: CGRect(x: 0.07, y: 0.07, width: 0.86, height: 0.86), background: .black, cornerRadius: 0, ellipse: false) { _, _, _ in },
        FrameDef(id: "arrondie", name: "Bordure arrondie", content: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), background: RGBA(r: 0.1, g: 0.1, b: 0.12), cornerRadius: 0.08, ellipse: false) { _, _, _ in },
        FrameDef(id: "double", name: "Double bordure", content: CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88), background: .white, cornerRadius: 0, ellipse: false) { ctx, size, r in
            ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.setLineWidth(max(2, size.height * 0.004))
            ctx.stroke(r.insetBy(dx: -size.height * 0.015, dy: -size.height * 0.015))
        },
        FrameDef(id: "polaroid", name: "Polaroïd", content: CGRect(x: 0.08, y: 0.06, width: 0.84, height: 0.72), background: RGBA(r: 0.97, g: 0.96, b: 0.92), cornerRadius: 0, ellipse: false) { _, _, _ in },
        FrameDef(id: "pellicule", name: "Bande de film", content: CGRect(x: 0, y: 0.13, width: 1, height: 0.74), background: RGBA(r: 0.05, g: 0.05, b: 0.05), cornerRadius: 0, ellipse: false) { ctx, size, _ in
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
            let hole = CGSize(width: size.height * 0.05, height: size.height * 0.06)
            var x: CGFloat = hole.width * 0.6
            while x < size.width {
                for y in [size.height * 0.035, size.height - size.height * 0.035 - hole.height] {
                    ctx.addPath(CGPath(roundedRect: CGRect(origin: CGPoint(x: x, y: y), size: hole), cornerWidth: hole.width * 0.2, cornerHeight: hole.width * 0.2, transform: nil))
                }
                x += hole.width * 2
            }
            ctx.fillPath()
        },
        FrameDef(id: "telephone", name: "Téléphone", content: CGRect(x: 0.345, y: 0.08, width: 0.31, height: 0.84), background: RGBA(r: 0.12, g: 0.12, b: 0.16), cornerRadius: 0.12, ellipse: false) { ctx, size, r in
            let body = r.insetBy(dx: -size.height * 0.018, dy: -size.height * 0.018)
            ctx.setStrokeColor(CGColor(gray: 0.05, alpha: 1)); ctx.setLineWidth(size.height * 0.022)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: body.width * 0.16, cornerHeight: body.width * 0.16, transform: nil)); ctx.strokePath()
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            let notch = CGRect(x: r.midX - r.width * 0.15, y: r.minY + r.height * 0.015, width: r.width * 0.3, height: r.height * 0.03)
            ctx.addPath(CGPath(roundedRect: notch, cornerWidth: notch.height / 2, cornerHeight: notch.height / 2, transform: nil)); ctx.fillPath()
        },
        FrameDef(id: "ordinateur", name: "Écran d'ordinateur", content: CGRect(x: 0.14, y: 0.08, width: 0.72, height: 0.72), background: RGBA(r: 0.85, g: 0.87, b: 0.9), cornerRadius: 0.01, ellipse: false) { ctx, size, r in
            ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(size.height * 0.02)
            ctx.stroke(r.insetBy(dx: -size.height * 0.01, dy: -size.height * 0.01))
            ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX - r.width * 0.08, y: r.maxY + size.height * 0.02, width: r.width * 1.16, height: size.height * 0.04), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        },
        FrameDef(id: "tablette", name: "Tablette", content: CGRect(x: 0.12, y: 0.1, width: 0.76, height: 0.8), background: RGBA(r: 0.92, g: 0.92, b: 0.94), cornerRadius: 0.03, ellipse: false) { ctx, size, r in
            let body = r.insetBy(dx: -size.height * 0.03, dy: -size.height * 0.03)
            ctx.setStrokeColor(CGColor(gray: 0.12, alpha: 1)); ctx.setLineWidth(size.height * 0.04)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: size.height * 0.05, cornerHeight: size.height * 0.05, transform: nil)); ctx.strokePath()
        },
        FrameDef(id: "carte-postale", name: "Carte postale", content: CGRect(x: 0.05, y: 0.08, width: 0.9, height: 0.84), background: RGBA(r: 0.98, g: 0.95, b: 0.88), cornerRadius: 0, ellipse: false) { ctx, size, r in
            let stamp = CGRect(x: r.maxX - size.height * 0.16, y: r.minY + size.height * 0.03, width: size.height * 0.13, height: size.height * 0.16)
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.25, blue: 0.2, alpha: 1)); ctx.fill(stamp)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(size.height * 0.006); ctx.stroke(stamp.insetBy(dx: 6, dy: 6))
        },
        FrameDef(id: "cinema", name: "Format cinéma", content: CGRect(x: 0, y: 0.12, width: 1, height: 0.76), background: .black, cornerRadius: 0, ellipse: false) { _, _, _ in },
        FrameDef(id: "rond", name: "Vignette ronde", content: CGRect(x: 0.2, y: 0.05, width: 0.6, height: 0.9), background: RGBA(r: 0.08, g: 0.08, b: 0.1), cornerRadius: 0, ellipse: true) { _, _, _ in },
        FrameDef(id: "neon", name: "Cadre néon", content: CGRect(x: 0.06, y: 0.08, width: 0.88, height: 0.84), background: RGBA(r: 0.04, g: 0.02, b: 0.08), cornerRadius: 0.04, ellipse: false) { ctx, size, r in
            for (w, a) in [(0.03, 0.15), (0.015, 0.35), (0.005, 1.0)] {
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.85, alpha: a)); ctx.setLineWidth(size.height * w)
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -size.height * 0.01, dy: -size.height * 0.01), cornerWidth: size.height * 0.04, cornerHeight: size.height * 0.04, transform: nil))
                ctx.strokePath()
            }
        },
        FrameDef(id: "dore", name: "Cadre doré", content: CGRect(x: 0.07, y: 0.09, width: 0.86, height: 0.82), background: RGBA(r: 0.75, g: 0.58, b: 0.22), cornerRadius: 0, ellipse: false) { ctx, size, r in
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 1)); ctx.setLineWidth(size.height * 0.008)
            ctx.stroke(r.insetBy(dx: -size.height * 0.02, dy: -size.height * 0.02))
            ctx.setStrokeColor(CGColor(srgbRed: 0.5, green: 0.35, blue: 0.1, alpha: 1)); ctx.setLineWidth(size.height * 0.004)
            ctx.stroke(r.insetBy(dx: -size.height * 0.006, dy: -size.height * 0.006))
        },
        FrameDef(id: "passe-partout", name: "Passe-partout", content: CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76), background: RGBA(r: 0.95, g: 0.93, b: 0.87), cornerRadius: 0, ellipse: false) { ctx, size, r in
            ctx.setStrokeColor(CGColor(gray: 0.7, alpha: 1)); ctx.setLineWidth(max(1, size.height * 0.002)); ctx.stroke(r)
        },
    ]

    static func apply(_ frame: FrameDef, to i: CIImage, context c: EffectContext) -> CIImage {
        let e = i.extent
        let W = e.width, H = e.height
        // Zone en coordonnées Core Image.
        let zone = CGRect(x: e.minX + frame.content.minX * W, y: e.minY + (1 - frame.content.maxY) * H,
                          width: frame.content.width * W, height: frame.content.height * H)
        let s = max(zone.width / W, zone.height / H)
        var placed = i.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: zone.midX, y: zone.midY))).cropped(to: zone)
        if frame.cornerRadius > 0 || frame.ellipse {
            let mask = shapeMask(zone, in: e, radius: frame.cornerRadius * min(zone.width, zone.height), ellipse: frame.ellipse)
            placed = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        var result = placed.composited(over: CI.solid(frame.background, e))
        if let overlay = overlayImage(frame, size: CGSize(width: W, height: H)) {
            result = CIImage(cgImage: overlay).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).composited(over: result)
        }
        return result.cropped(to: e)
    }

    static func shapeMask(_ rect: CGRect, in e: CGRect, radius: CGFloat, ellipse: Bool) -> CIImage {
        let w = max(1, Int(e.width)), h = max(1, Int(e.height))
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(gray: 1, alpha: 1)
        let local = rect.offsetBy(dx: -e.minX, dy: -e.minY)
        if ellipse {
            ctx.fillEllipse(in: local)
        } else {
            ctx.addPath(CGPath(roundedRect: local, cornerWidth: min(radius, local.width / 2), cornerHeight: min(radius, local.height / 2), transform: nil))
            ctx.fillPath()
        }
        guard let image = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }

    private static func overlayImage(_ frame: FrameDef, size: CGSize) -> CGImage? {
        let key = "\(frame.id)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Dessin avec l'origine en haut à gauche.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let r = CGRect(x: frame.content.minX * size.width, y: frame.content.minY * size.height,
                       width: frame.content.width * size.width, height: frame.content.height * size.height)
        frame.draw(ctx, size, r)
        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }
}

/// Stylisation (lot V2) : 20 effets artistiques.
enum Stylize {
    static func effects() -> [EffectDef] {
        func def(_ id: String, _ name: String, _ f: @escaping (CIImage, EffectContext) -> CIImage) -> EffectDef {
            EffectDef(id: "style-\(id)", name: name, category: .stylisation, image: f)
        }
        return [
            def("dessin-anime", "Dessin animé") { i, c in
                let poster = i.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6]).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
                let edges = i.applyingFilter("CILineOverlay", parameters: ["inputNRNoiseLevel": 0.07, "inputEdgeIntensity": 1, "inputThreshold": 0.1, "inputContrast": 50])
                return edges.composited(over: poster).cropped(to: i.extent)
            },
            def("bd", "Bande dessinée") { i, c in
                i.applyingFilter("CIComicEffect").cropped(to: i.extent)
            },
            def("demi-teinte", "Demi-teinte") { i, c in
                i.applyingFilter("CICMYKHalftone", parameters: [kCIInputWidthKey: max(4, c.canvas.height * 0.008), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            },
            def("points", "Trame de points") { i, c in
                i.applyingFilter("CIDotScreen", parameters: [kCIInputWidthKey: max(4, c.canvas.height * 0.008), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            },
            def("hachures", "Hachures") { i, c in
                i.applyingFilter("CIHatchedScreen", parameters: [kCIInputWidthKey: max(4, c.canvas.height * 0.006), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            },
            def("contour", "Contour") { i, c in
                i.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4]).cropped(to: i.extent)
            },
            def("contour-blanc", "Croquis") { i, c in
                i.applyingFilter("CILineOverlay", parameters: ["inputContrast": 60]).composited(over: CI.solid(.white, i.extent)).cropped(to: i.extent)
            },
            def("aquarelle", "Aquarelle") { i, c in
                CI.fade(i.applyingFilter("CIMedianFilter").applyingFilter("CIMedianFilter").clampedToExtent()
                    .applyingGaussianBlur(sigma: c.canvas.height * 0.002).cropped(to: i.extent)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2]), amount: 0.3)
            },
            def("peinture", "Peinture à l'huile") { i, c in
                i.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: max(3, c.canvas.height * 0.006), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25]).cropped(to: i.extent)
            },
            def("thermique", "Caméra thermique") { i, c in
                i.applyingFilter("CIThermal").cropped(to: i.extent)
            },
            def("rayons-x", "Rayons X") { i, c in i.applyingFilter("CIXRay").cropped(to: i.extent) },
            def("posterisation", "Postérisation") { i, c in i.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 4]).cropped(to: i.extent) },
            def("relief", "Relief") { i, c in
                i.applyingFilter("CIPhotoEffectMono").clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
                    "inputWeights": CIVector(values: [-2, -1, 0, -1, 1, 1, 0, 1, 2], count: 9), "inputBias": 0.1,
                ]).cropped(to: i.extent)
            },
            def("pointillisme", "Pointillisme") { i, c in
                i.applyingFilter("CIPointillize", parameters: [kCIInputRadiusKey: max(3, c.canvas.height * 0.006), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            },
            def("pop-art", "Pop art") { i, c in
                i.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 3]).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 2]).cropped(to: i.extent)
            },
            def("noir-blanc-encre", "Encre") { i, c in
                i.applyingFilter("CIPhotoEffectNoir").applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3]).cropped(to: i.extent)
            },
            def("vitrail", "Vitrail") { i, c in
                let cells = i.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: max(8, c.canvas.height * 0.025), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                return cells.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 2]).composited(over: cells).cropped(to: i.extent)
            },
            def("gravure", "Gravure") { i, c in
                i.applyingFilter("CILineScreen", parameters: [kCIInputWidthKey: max(3, c.canvas.height * 0.005), kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputAngleKey: 0.6]).cropped(to: i.extent)
            },
            def("negatif-couleur", "Solarisation") { i, c in
                CI.mix(i, i.applyingFilter("CIColorInvert").applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: 3.1]), amount: 0.6)
            },
            def("flou-artistique", "Flou artistique") { i, c in
                i.applyingFilter("CIBokehBlur", parameters: [kCIInputRadiusKey: c.canvas.height * 0.012, "inputRingAmount": 0.2, "inputRingSize": 0.1, "inputSoftness": 1]).cropped(to: i.extent)
            },
        ]
    }
}

/// Saisonniers et fêtes (lot V2) : 15 habillages animés.
enum Seasonal {
    static func effects() -> [EffectDef] {
        func def(_ id: String, _ name: String, _ f: @escaping (CIImage, EffectContext) -> CIImage) -> EffectDef {
            EffectDef(id: "saison-\(id)", name: name, category: .saisons, image: f)
        }
        return [
            def("noel", "Noël") { i, c in Particles.overlay(CI.temperature(i, warmth: 0.2, tint: 0), c, kind: .snow, count: 140, color: .white) },
            def("sapin", "Guirlande lumineuse") { i, c in Particles.overlay(i, c, kind: .firefly, count: 70, color: nil) },
            def("nouvel-an", "Nouvel An") { i, c in Particles.overlay(i, c, kind: .firework, count: 5, color: nil) },
            def("cotillons", "Cotillons") { i, c in Particles.overlay(i, c, kind: .confetti, count: 220, color: nil) },
            def("halloween", "Halloween") { i, c in
                CI.vignette(CI.temperature(i, warmth: 0.6, tint: 0.2).applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.1]), amount: 1.5)
            },
            def("toussaint", "Brume d'automne") { i, c in Particles.overlay(i, c, kind: .smoke, count: 24, color: RGBA(r: 0.9, g: 0.85, b: 0.8, a: 0.2)) },
            def("paques", "Pâques") { i, c in Particles.overlay(i, c, kind: .petal, count: 60, color: nil) },
            def("printemps", "Printemps") { i, c in Particles.overlay(CI.temperature(i, warmth: 0.1, tint: 0.15), c, kind: .petal, count: 45, color: RGBA(r: 1, g: 0.75, b: 0.85)) },
            def("ete", "Été") { i, c in Light.sunbeams(CI.temperature(i, warmth: 0.35, tint: 0), c, color: RGBA(r: 1, g: 0.85, b: 0.5), moving: false) },
            def("automne", "Automne") { i, c in Particles.overlay(CI.temperature(i, warmth: 0.5, tint: 0.05), c, kind: .petal, count: 40, color: RGBA(r: 0.9, g: 0.45, b: 0.1)) },
            def("hiver", "Hiver") { i, c in Particles.overlay(CI.temperature(i, warmth: -0.5, tint: 0), c, kind: .flake, count: 60, color: .white) },
            def("anniversaire", "Anniversaire") { i, c in Particles.overlay(Particles.overlay(i, c, kind: .confetti, count: 120, color: nil), c, kind: .star, count: 20, color: RGBA(r: 1, g: 0.85, b: 0.3)) },
            def("saint-valentin", "Saint-Valentin") { i, c in Particles.overlay(CI.temperature(i, warmth: 0.15, tint: 0.3), c, kind: .heart, count: 45, color: RGBA(r: 1, g: 0.3, b: 0.45)) },
            def("rentree", "Rentrée") { i, c in Particles.overlay(i, c, kind: .note, count: 18, color: RGBA(r: 1, g: 0.9, b: 0.4)) },
            def("fete-nationale", "Fête nationale") { i, c in Particles.overlay(i, c, kind: .firework, count: 7, color: nil) },
        ]
    }
}
