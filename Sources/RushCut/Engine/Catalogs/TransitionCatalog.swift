import Foundation
import CoreImage
import CoreGraphics

struct TransitionDef: Identifiable {
    let id: String
    let name: String
    let category: String
    /// Passe de l'image `from` (p = 0) à l'image `to` (p = 1).
    let render: (CIImage, CIImage, Double, CGRect, Int) -> CIImage
}

/// 60 transitions originales (recettes Core Image).
enum TransitionCatalog {
    static let all: [TransitionDef] = build()
    static let byID: [String: TransitionDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static var categories: [String] { var seen: [String] = []; for t in all where !seen.contains(t.category) { seen.append(t.category) }; return seen }

    static func render(_ id: String, from: CIImage, to: CIImage, progress: Double, extent: CGRect, frame: Int) -> CIImage {
        let p = min(1, max(0, progress))
        guard let def = byID[id] else { return CI.mix(from, to, amount: p) }
        return def.render(from.cropped(to: extent), to.cropped(to: extent), p, extent, frame).cropped(to: extent)
    }

    // MARK: Outils

    static func smooth(_ p: Double) -> Double { p * p * (3 - 2 * p) }

    static func move(_ i: CIImage, dx: CGFloat, dy: CGFloat) -> CIImage { i.transformed(by: CGAffineTransform(translationX: dx, y: dy)) }

    static func scaled(_ i: CIImage, _ s: CGFloat, rotation: CGFloat = 0, in e: CGRect) -> CIImage {
        i.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
    }

    static func masked(_ from: CIImage, _ to: CIImage, mask: CIImage) -> CIImage {
        to.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: from, kCIInputMaskImageKey: mask])
    }

    /// Masque dessiné (blanc = image d'arrivée), à basse résolution puis agrandi.
    static func drawnMask(_ e: CGRect, _ draw: (CGContext, CGSize) -> Void) -> CIImage {
        let scale = min(1, 480 / max(e.width, e.height))
        let w = max(2, Int(e.width * scale)), h = max(2, Int(e.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        draw(ctx, CGSize(width: w, height: h))
        guard let img = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(w), y: e.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
    }

    static func linearMask(_ e: CGRect, angle: CGFloat, p: Double, softness: CGFloat = 0.06) -> CIImage {
        let diag = hypot(e.width, e.height)
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let center = CGPoint(x: e.midX, y: e.midY)
        let travel = diag * (CGFloat(p) * (1 + 2 * softness) - 0.5 - softness)
        let p0 = CGPoint(x: center.x + dir.x * (travel - diag * softness), y: center.y + dir.y * (travel - diag * softness))
        let p1 = CGPoint(x: center.x + dir.x * (travel + diag * softness), y: center.y + dir.y * (travel + diag * softness))
        return CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: p0.x, y: p0.y), "inputPoint1": CIVector(x: p1.x, y: p1.y),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])!.outputImage!.cropped(to: e)
    }

    static func radialMask(_ e: CGRect, p: Double, inverted: Bool) -> CIImage {
        let maxR = hypot(e.width, e.height) / 2
        let r = maxR * CGFloat(inverted ? 1 - p : p)
        return CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), "inputRadius0": max(0, r - 20), "inputRadius1": r + 1,
            "inputColor0": inverted ? CIColor(red: 0, green: 0, blue: 0) : CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": inverted ? CIColor(red: 1, green: 1, blue: 1) : CIColor(red: 0, green: 0, blue: 0),
        ])!.outputImage!.cropped(to: e)
    }

    static func perspective(_ i: CIImage, e: CGRect, angle: Double, axisVertical: Bool, side: CGFloat) -> CIImage {
        // Rotation autour d'un bord (cube) : rétrécit un côté.
        let shrink = CGFloat(sin(angle)) * 0.25
        let width = CGFloat(cos(angle))
        var tl = CGPoint(x: e.minX, y: e.maxY), tr = CGPoint(x: e.maxX, y: e.maxY)
        var bl = CGPoint(x: e.minX, y: e.minY), br = CGPoint(x: e.maxX, y: e.minY)
        if axisVertical {
            let w = e.width * width
            if side > 0 {
                tl.x = e.maxX - w; bl.x = e.maxX - w
                tl.y -= e.height * shrink; bl.y += e.height * shrink
            } else {
                tr.x = e.minX + w; br.x = e.minX + w
                tr.y -= e.height * shrink; br.y += e.height * shrink
            }
        } else {
            let h = e.height * width
            if side > 0 {
                tl.y = e.minY + h; tr.y = e.minY + h
                tl.x += e.width * shrink; tr.x -= e.width * shrink
            } else {
                bl.y = e.maxY - h; br.y = e.maxY - h
                bl.x += e.width * shrink; br.x -= e.width * shrink
            }
        }
        return i.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: tl), "inputTopRight": CIVector(cgPoint: tr),
            "inputBottomLeft": CIVector(cgPoint: bl), "inputBottomRight": CIVector(cgPoint: br),
        ])
    }

    // MARK: Catalogue

    private static func build() -> [TransitionDef] {
        var list: [TransitionDef] = []
        func add(_ id: String, _ name: String, _ cat: String, _ f: @escaping (CIImage, CIImage, Double, CGRect, Int) -> CIImage) {
            list.append(TransitionDef(id: id, name: name, category: cat, render: f))
        }
        let black = RGBA.black, white = RGBA.white

        // Fondus (5)
        add("fondu", "Fondu enchaîné", "Fondus") { a, b, p, _, _ in CI.mix(a, b, amount: p) }
        add("fondu-noir", "Fondu au noir", "Fondus") { a, b, p, e, _ in
            p < 0.5 ? CI.mix(a, CI.solid(black, e), amount: p * 2) : CI.mix(CI.solid(black, e), b, amount: (p - 0.5) * 2)
        }
        add("fondu-blanc", "Fondu au blanc", "Fondus") { a, b, p, e, _ in
            p < 0.5 ? CI.mix(a, CI.solid(white, e), amount: p * 2) : CI.mix(CI.solid(white, e), b, amount: (p - 0.5) * 2)
        }
        add("flou", "Fondu flou", "Fondus") { a, b, p, e, _ in
            let s = sin(p * .pi) * e.height * 0.03
            return CI.mix(a.clampedToExtent().applyingGaussianBlur(sigma: s).cropped(to: e), b.clampedToExtent().applyingGaussianBlur(sigma: s).cropped(to: e), amount: p)
        }
        add("eclat", "Éclat lumineux", "Fondus") { a, b, p, e, _ in
            let mid = CI.mix(a, b, amount: smooth(p))
            return mid.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.5 * sin(p * .pi)])
        }
        // Zooms (4)
        add("zoom-avant", "Zoom avant", "Zooms") { a, b, p, e, _ in CI.mix(scaled(a, 1 + CGFloat(p) * 0.6, in: e), scaled(b, 0.6 + CGFloat(p) * 0.4, in: e).composited(over: CI.solid(black, e)), amount: p) }
        add("zoom-arriere", "Zoom arrière", "Zooms") { a, b, p, e, _ in CI.mix(scaled(a, 1 - CGFloat(p) * 0.4, in: e).composited(over: CI.solid(black, e)), scaled(b, 1.6 - CGFloat(p) * 0.6, in: e), amount: p) }
        add("zoom-tournant", "Zoom tournant", "Zooms") { a, b, p, e, _ in
            let s = smooth(p)
            return CI.mix(scaled(a, 1 + CGFloat(s) * 1.5, rotation: CGFloat(s) * .pi, in: e), scaled(b, 0.3 + CGFloat(s) * 0.7, rotation: CGFloat(s - 1) * .pi, in: e).composited(over: CI.solid(black, e)), amount: s)
        }
        add("trou-noir", "Aspiration", "Zooms") { a, b, p, e, _ in
            let s = smooth(p)
            let pinched = a.clampedToExtent().applyingFilter("CIPinchDistortion", parameters: [kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: e.height, kCIInputScaleKey: min(1, s * 2)]).cropped(to: e)
            return CI.mix(pinched, b, amount: max(0, s * 2 - 1))
        }
        // Glissements et poussées (8)
        let dirs: [(String, String, CGFloat, CGFloat)] = [("gauche", "vers la gauche", -1, 0), ("droite", "vers la droite", 1, 0), ("haut", "vers le haut", 0, 1), ("bas", "vers le bas", 0, -1)]
        for (id, label, dx, dy) in dirs {
            add("glissement-\(id)", "Glissement \(label)", "Glissements") { a, b, p, e, _ in
                let s = CGFloat(smooth(p))
                return move(b, dx: -dx * e.width * (1 - s), dy: -dy * e.height * (1 - s)).composited(over: a)
            }
            add("poussee-\(id)", "Poussée \(label)", "Glissements") { a, b, p, e, _ in
                let s = CGFloat(smooth(p))
                return move(b, dx: -dx * e.width * (1 - s), dy: -dy * e.height * (1 - s)).composited(over: move(a, dx: dx * e.width * s, dy: dy * e.height * s))
            }
        }
        // Balayages (8)
        let swipes: [(String, String, CGFloat)] = [("droite", "vers la droite", 0), ("gauche", "vers la gauche", .pi), ("haut", "vers le haut", .pi / 2), ("bas", "vers le bas", -.pi / 2)]
        for (id, label, angle) in swipes {
            add("balayage-\(id)", "Balayage \(label)", "Balayages") { a, b, p, e, _ in masked(a, b, mask: linearMask(e, angle: angle + .pi, p: p)) }
        }
        let diagonals: [(String, String, CGFloat)] = [("1", "Diagonale ↗", .pi / 4), ("2", "Diagonale ↖", 3 * .pi / 4), ("3", "Diagonale ↙", -3 * .pi / 4), ("4", "Diagonale ↘", -.pi / 4)]
        for (id, name, angle) in diagonals {
            add("diagonale-\(id)", name, "Balayages") { a, b, p, e, _ in masked(a, b, mask: linearMask(e, angle: angle + .pi, p: p, softness: 0.1)) }
        }
        add("balayage-radial", "Balayage d'horloge", "Balayages") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let c = CGPoint(x: s.width / 2, y: s.height / 2)
                ctx.move(to: c)
                ctx.addArc(center: c, radius: hypot(s.width, s.height), startAngle: .pi / 2, endAngle: .pi / 2 - CGFloat(p) * 2 * .pi, clockwise: true)
                ctx.closePath(); ctx.fillPath()
            })
        }
        // Formes (10)
        add("iris-ouvert", "Iris qui s'ouvre", "Formes") { a, b, p, e, _ in masked(a, b, mask: radialMask(e, p: smooth(p), inverted: false)) }
        add("iris-ferme", "Iris qui se ferme", "Formes") { a, b, p, e, _ in
            let s = smooth(p)
            return s < 0.5 ? masked(CI.solid(black, e), a, mask: radialMask(e, p: 1 - s * 2, inverted: false))
                : masked(CI.solid(black, e), b, mask: radialMask(e, p: (s - 0.5) * 2, inverted: false))
        }
        add("losange", "Losange", "Formes") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let r = max(s.width, s.height) * CGFloat(smooth(p)) * 1.05
                let c = CGPoint(x: s.width / 2, y: s.height / 2)
                ctx.move(to: CGPoint(x: c.x, y: c.y + r)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
                ctx.addLine(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x - r, y: c.y)); ctx.closePath(); ctx.fillPath()
            })
        }
        add("coeur", "Cœur", "Formes") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let r = max(s.width, s.height) * CGFloat(smooth(p)) * 1.6
                ctx.translateBy(x: 0, y: s.height); ctx.scaleBy(x: 1, y: -1)
                ctx.addPath(StickerShapes.heart(in: CGRect(x: s.width / 2 - r / 2, y: s.height / 2 - r / 2, width: r, height: r))); ctx.fillPath()
            })
        }
        add("etoile", "Étoile", "Formes") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let r = max(s.width, s.height) * CGFloat(smooth(p)) * 2.2
                ctx.addPath(StickerShapes.star(in: CGRect(x: s.width / 2 - r / 2, y: s.height / 2 - r / 2, width: r, height: r))); ctx.fillPath()
            })
        }
        for (id, name, vertical) in [("h", "Store vénitien horizontal", false), ("v", "Store vénitien vertical", true)] {
            add("store-\(id)", name, "Formes") { a, b, p, e, _ in
                masked(a, b, mask: drawnMask(e) { ctx, s in
                    let n = 10
                    for k in 0..<n {
                        if vertical {
                            let w = s.width / CGFloat(n)
                            ctx.fill(CGRect(x: CGFloat(k) * w, y: 0, width: w * CGFloat(smooth(p)), height: s.height))
                        } else {
                            let h = s.height / CGFloat(n)
                            ctx.fill(CGRect(x: 0, y: CGFloat(k) * h, width: s.width, height: h * CGFloat(smooth(p))))
                        }
                    }
                })
            }
        }
        add("damier", "Damier", "Formes") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let n = 8, cell = max(s.width, s.height) / CGFloat(n)
                for i in 0..<n { for j in 0..<n {
                    let delay = Double((i + j) % 2) * 0.5
                    let local = min(1, max(0, (p - delay * 0.5) / 0.5))
                    let size = cell * CGFloat(local)
                    ctx.fill(CGRect(x: CGFloat(i) * cell + (cell - size) / 2, y: CGFloat(j) * cell + (cell - size) / 2, width: size, height: size))
                } }
            })
        }
        add("rideau-h", "Rideau qui s'ouvre", "Formes") { a, b, p, e, _ in
            let s = CGFloat(smooth(p))
            let left = move(a.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height)), dx: -e.width / 2 * s, dy: 0)
            let right = move(a.cropped(to: CGRect(x: e.midX, y: e.minY, width: e.width / 2, height: e.height)), dx: e.width / 2 * s, dy: 0)
            return left.composited(over: right).composited(over: b)
        }
        add("rideau-v", "Rideau vertical", "Formes") { a, b, p, e, _ in
            let s = CGFloat(smooth(p))
            let bottom = move(a.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 2)), dx: 0, dy: -e.height / 2 * s)
            let top = move(a.cropped(to: CGRect(x: e.minX, y: e.midY, width: e.width, height: e.height / 2)), dx: 0, dy: e.height / 2 * s)
            return top.composited(over: bottom).composited(over: b)
        }
        // 3D (6)
        let cubes: [(String, String, Bool, CGFloat)] = [("gauche", "Cube vers la gauche", true, -1), ("droite", "Cube vers la droite", true, 1), ("haut", "Cube vers le haut", false, 1), ("bas", "Cube vers le bas", false, -1)]
        for (id, name, vertical, side) in cubes {
            add("cube-\(id)", name, "3D") { a, b, p, e, _ in
                let s = smooth(p)
                let outgoing = perspective(a, e: e, angle: s * .pi / 2 * 0.98, axisVertical: vertical, side: -side)
                let incoming = perspective(b, e: e, angle: (1 - s) * .pi / 2 * 0.98, axisVertical: vertical, side: side)
                return incoming.composited(over: outgoing).composited(over: CI.solid(black, e))
            }
        }
        add("page-droite", "Page tournée", "3D") { a, b, p, e, _ in
            a.applyingFilter("CIPageCurlTransition", parameters: [kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: e), kCIInputTimeKey: p,
                                                                   kCIInputAngleKey: Double.pi, kCIInputRadiusKey: e.height * 0.12, "inputBacksideImage": a])
        }
        add("page-gauche", "Page tournée inversée", "3D") { a, b, p, e, _ in
            a.applyingFilter("CIPageCurlTransition", parameters: [kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: e), kCIInputTimeKey: p,
                                                                   kCIInputAngleKey: 0.0, kCIInputRadiusKey: e.height * 0.12, "inputBacksideImage": a])
        }
        // Effets (12)
        add("copieur", "Photocopieur", "Effets") { a, b, p, e, _ in
            a.applyingFilter("CICopyMachineTransition", parameters: [kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: e), kCIInputTimeKey: p, kCIInputWidthKey: e.width * 0.1])
        }
        add("ondulation", "Ondulation", "Effets") { a, b, p, e, _ in
            a.applyingFilter("CIRippleTransition", parameters: [kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: e), kCIInputTimeKey: p,
                                                                kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputWidthKey: e.height * 0.1, kCIInputScaleKey: 40,
                                                                kCIInputShadingImageKey: CI.solid(white, CGRect(x: 0, y: 0, width: 64, height: 64))])
        }
        add("desintegration", "Désintégration", "Effets") { a, b, p, e, frame in
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12)).cropped(to: e)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            return a.applyingFilter("CIDisintegrateWithMaskTransition", parameters: [kCIInputTargetImageKey: b, kCIInputMaskImageKey: noise, kCIInputTimeKey: p,
                                                                                    "inputShadowRadius": 0, "inputShadowDensity": 0])
        }
        add("accordeon", "Accordéon", "Effets") { a, b, p, e, _ in
            a.applyingFilter("CIAccordionFoldTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p, "inputNumberOfFolds": 4, "inputFoldShadowAmount": 0.2, "inputBottomHeight": 0])
        }
        add("mod", "Éclats", "Effets") { a, b, p, e, _ in
            a.applyingFilter("CIModTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p, kCIInputCenterKey: CIVector(x: e.midX, y: e.midY),
                                                            kCIInputAngleKey: 2, kCIInputRadiusKey: e.height * 0.15, "inputCompression": 300])
        }
        add("flash", "Flash", "Effets") { a, b, p, e, _ in
            a.applyingFilter("CIFlashTransition", parameters: [kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: e), kCIInputTimeKey: p,
                                                              kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputColorKey: CIColor(red: 1, green: 0.95, blue: 0.85),
                                                              "inputMaxStriationRadius": 2.6, "inputStriationStrength": 0.5, "inputStriationContrast": 1.4, "inputFadeThreshold": 0.85])
        }
        add("glitch", "Glitch", "Effets") { a, b, p, e, frame in
            let base = p < 0.5 ? a : b
            let ctx = EffectContext(local: p, duration: 1, frame: frame, intensity: 1, params: [:], canvas: e.size)
            return CI.mix(Glitch.rgbSplit(Glitch.blocks(base, ctx), ctx, strength: 3 * sin(p * .pi), animated: true), base, amount: 1 - sin(p * .pi))
        }
        add("fuite-lumiere", "Fuite de lumière", "Effets") { a, b, p, e, _ in
            let ctx = EffectContext(local: p * 3, duration: 1, frame: 0, intensity: 1, params: [:], canvas: e.size)
            return CI.mix(CI.mix(a, b, amount: smooth(p)), Light.leak(CI.mix(a, b, amount: smooth(p)), ctx, color: RGBA(r: 1, g: 0.6, b: 0.2)), amount: sin(p * .pi))
        }
        add("pixellisation", "Pixellisation", "Effets") { a, b, p, e, _ in
            let base = p < 0.5 ? a : b
            let amount = sin(p * .pi)
            return amount < 0.03 ? base : base.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, e.height * 0.06 * amount), kCIInputCenterKey: CIVector(x: e.midX, y: e.midY)])
        }
        add("rotation", "Rotation", "Effets") { a, b, p, e, _ in
            let s = smooth(p)
            return s < 0.5 ? scaled(a, 1 - CGFloat(s), rotation: CGFloat(s) * .pi, in: e).composited(over: CI.solid(black, e))
                : scaled(b, CGFloat(s), rotation: CGFloat(s - 1) * .pi, in: e).composited(over: CI.solid(black, e))
        }
        add("spirale", "Spirale", "Effets") { a, b, p, e, _ in
            let angle = sin(p * .pi) * 6
            let tw = { (i: CIImage) in i.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: e.height * 0.7, kCIInputAngleKey: angle]).cropped(to: e) }
            return CI.mix(tw(a), tw(b), amount: smooth(p))
        }
        add("chute", "Chute", "Effets") { a, b, p, e, _ in
            let s = CGFloat(p * p)
            return scaled(move(a, dx: 0, dy: -e.height * s), 1, rotation: s * 0.3, in: e.offsetBy(dx: 0, dy: -e.height * s)).composited(over: b)
        }
        // Mouvement (7)
        for (id, name, angle) in [("h", "Flou de mouvement horizontal", 0.0), ("v", "Flou de mouvement vertical", Double.pi / 2)] {
            add("flou-mouvement-\(id)", name, "Mouvement") { a, b, p, e, _ in
                let r = sin(p * .pi) * e.height * 0.06
                let blur = { (i: CIImage) in i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: r, kCIInputAngleKey: angle]).cropped(to: e) }
                return CI.mix(blur(a), blur(b), amount: smooth(p))
            }
        }
        for (id, name, horizontal) in [("h", "Étirement horizontal", true), ("v", "Étirement vertical", false)] {
            add("etirement-\(id)", name, "Mouvement") { a, b, p, e, _ in
                let s = 1 + CGFloat(sin(p * .pi)) * 0.8
                let stretch = { (i: CIImage) in i.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
                    .concatenating(CGAffineTransform(scaleX: horizontal ? s : 1, y: horizontal ? 1 : s)).concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))) }
                return CI.mix(stretch(a), stretch(b), amount: smooth(p))
            }
        }
        add("ouverture-h", "Ouverture horizontale", "Mouvement") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let h = s.height * CGFloat(smooth(p)); ctx.fill(CGRect(x: 0, y: (s.height - h) / 2, width: s.width, height: h))
            })
        }
        add("ouverture-v", "Ouverture verticale", "Mouvement") { a, b, p, e, _ in
            masked(a, b, mask: drawnMask(e) { ctx, s in
                let w = s.width * CGFloat(smooth(p)); ctx.fill(CGRect(x: (s.width - w) / 2, y: 0, width: w, height: s.height))
            })
        }
        for (id, name, vertical) in [("h", "Barres horizontales", false), ("v", "Barres verticales", true)] {
            add("barres-\(id)", name, "Mouvement") { a, b, p, e, _ in
                a.applyingFilter("CIBarsSwipeTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p, kCIInputAngleKey: vertical ? Double.pi / 2 : 0,
                                                                      kCIInputWidthKey: e.height * 0.06, "inputBarOffset": 10])
            }
        }
        return list
    }
}

