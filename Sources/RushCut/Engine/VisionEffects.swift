import Foundation
import CoreImage
import Vision

/// Détourage (personnes ou sujet principal) et retouche du visage, calculés image par image sur le Mac.
enum Segmenter {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var masks: [String: CIImage] = [:]
        var order: [String] = []
        var faces: [String: [CGRect]] = [:]
        var faceOrder: [String] = []
    }
    private static let cache = Cache()

    private static func remember(_ key: String, _ mask: CIImage) {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.masks[key] = mask
        cache.order.append(key)
        if cache.order.count > 24 { cache.masks[cache.order.removeFirst()] = nil }
    }

    /// Masque (blanc = sujet) à la taille de l'image ; `key` identifie le clip et l'image (aperçu et export partagent le cache).
    static func mask(for image: CIImage, mode: CutoutMode, key: String, accurate: Bool) -> CIImage? {
        cache.lock.lock()
        if let hit = cache.masks[key] { cache.lock.unlock(); return hit }
        cache.lock.unlock()
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8 else { return nil }
        let input = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let handler = VNImageRequestHandler(ciImage: input, options: [:])
        var buffer: CVPixelBuffer?
        switch mode {
        case .personne:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = accurate ? .accurate : .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? handler.perform([request])
            buffer = request.results?.first?.pixelBuffer
        case .sujet:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([request])
            if let result = request.results?.first {
                buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            }
        }
        guard let buffer else { return nil }
        let raw = CIImage(cvPixelBuffer: buffer)
        let sx = extent.width / raw.extent.width, sy = extent.height / raw.extent.height
        let mask = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .cropped(to: extent)
        remember(key, mask)
        return mask
    }

    /// Ne garde que le sujet (le reste devient transparent).
    static func cutout(_ image: CIImage, mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Visages (rectangles en coordonnées Core Image), recherchés au plus toutes les 4 images.
    static func faces(in image: CIImage, key: String) -> [CGRect] {
        cache.lock.lock()
        if let hit = cache.faces[key] { cache.lock.unlock(); return hit }
        cache.lock.unlock()
        let extent = image.extent
        let input = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: input, options: [:]).perform([request])
        let rects = (request.results ?? []).map { o in
            CGRect(x: extent.minX + o.boundingBox.minX * extent.width, y: extent.minY + o.boundingBox.minY * extent.height,
                   width: o.boundingBox.width * extent.width, height: o.boundingBox.height * extent.height)
        }
        cache.lock.lock()
        cache.faces[key] = rects
        cache.faceOrder.append(key)
        if cache.faceOrder.count > 60 { cache.faces[cache.faceOrder.removeFirst()] = nil }
        cache.lock.unlock()
        return rects
    }

    /// Lissage de la peau et éclat, limités aux visages (ellipses adoucies).
    static func retouch(_ image: CIImage, retouch: Retouch, faces: [CGRect]) -> CIImage {
        guard !faces.isEmpty else { return image }
        let extent = image.extent
        var mask = CIImage(color: .black).cropped(to: extent)
        for f in faces {
            let r = f.insetBy(dx: -f.width * 0.12, dy: -f.height * 0.18)
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: r.midX, y: r.midY), "inputRadius0": max(r.width, r.height) * 0.32,
                "inputRadius1": max(r.width, r.height) * 0.62, "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!
            let squeezed = gradient.transformed(by: CGAffineTransform(translationX: -r.midX, y: -r.midY)
                .concatenating(CGAffineTransform(scaleX: r.width / max(r.width, r.height), y: r.height / max(r.width, r.height)))
                .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY)))
            mask = squeezed.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: extent)
        }
        var treated = image
        if retouch.smooth > 0 {
            let radius = Double(min(extent.width, extent.height)) * 0.006 * (0.5 + retouch.smooth)
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
            treated = CI.mix(image, blurred, amount: 0.75 * retouch.smooth)
        }
        if retouch.brighten > 0 {
            treated = treated.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45 * retouch.brighten])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25 * retouch.brighten])
        }
        return treated.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            .cropped(to: extent)
    }
}

/// Effets sur le corps : ils utilisent le masque de la personne (contexte `personMask`).
enum BodyEffects {
    private static func colored(_ mask: CIImage, _ color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: mask.extent)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: mask.extent), kCIInputMaskImageKey: mask])
    }

    private static func outline(_ mask: CIImage, width: Double) -> CIImage {
        let dilated = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width])
        return mask.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: dilated]).cropped(to: mask.extent)
    }

    static func effects() -> [EffectDef] {
        func body(_ id: String, _ name: String, _ f: @escaping (CIImage, CIImage, EffectContext) -> CIImage) -> EffectDef {
            EffectDef(id: id, name: name, category: .corps, image: { image, ctx in
                guard let mask = ctx.personMask else { return image }
                return f(image, mask, ctx).cropped(to: image.extent)
            }, needsSegmentation: true)
        }
        let h = { (ctx: EffectContext) in Double(ctx.canvas.height) }
        return [
            body("corps-contour-neon", "Contour néon") { img, m, ctx in
                let edge = outline(m, width: h(ctx) * 0.008)
                let glow = colored(edge, CIColor(red: 0.2, green: 1, blue: 1)).applyingGaussianBlur(sigma: h(ctx) * 0.006)
                return glow.composited(over: colored(edge, .white).composited(over: img))
            },
            body("corps-contour-arc", "Contour arc-en-ciel") { img, m, ctx in
                let edge = outline(m, width: h(ctx) * 0.01)
                let hue = CIColor(red: 0.5 + 0.5 * sin(ctx.local * 3), green: 0.5 + 0.5 * sin(ctx.local * 3 + 2.1), blue: 0.5 + 0.5 * sin(ctx.local * 3 + 4.2))
                return colored(edge, hue).applyingGaussianBlur(sigma: h(ctx) * 0.004).composited(over: img)
            },
            body("corps-halo", "Halo lumineux") { img, m, ctx in
                let halo = colored(m, CIColor(red: 1, green: 0.85, blue: 0.4)).applyingGaussianBlur(sigma: h(ctx) * 0.04)
                return Segmenter.cutout(img, mask: m).composited(over: halo.composited(over: img))
            },
            body("corps-fond-flou", "Fond flou (portrait)") { img, m, ctx in
                let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: h(ctx) * 0.02).cropped(to: img.extent)
                return Segmenter.cutout(img, mask: m).composited(over: blurred)
            },
            body("corps-fond-nb", "Fond noir et blanc") { img, m, _ in
                let gray = img.applyingFilter("CIPhotoEffectMono")
                return Segmenter.cutout(img, mask: m).composited(over: gray)
            },
            body("corps-projecteur", "Projecteur") { img, m, _ in
                let dark = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2])
                return Segmenter.cutout(img, mask: m).composited(over: dark)
            },
            body("corps-silhouette", "Silhouette colorée") { img, m, ctx in
                let hue = CIColor(red: 1, green: 0.25 + 0.2 * sin(ctx.local * 2), blue: 0.55)
                return colored(m, hue).composited(over: img)
            },
            body("corps-clones", "Clones") { img, m, ctx in
                let person = Segmenter.cutout(img, mask: m)
                let w = img.extent.width * 0.22
                let fade = CIVector(x: 0, y: 0, z: 0, w: 0.55)
                let left = person.transformed(by: CGAffineTransform(translationX: -w, y: 0)).applyingFilter("CIColorMatrix", parameters: ["inputAVector": fade])
                let right = person.transformed(by: CGAffineTransform(translationX: w, y: 0)).applyingFilter("CIColorMatrix", parameters: ["inputAVector": fade])
                _ = ctx
                return person.composited(over: left.composited(over: right.composited(over: img)))
            },
            body("corps-ombre", "Ombre portée") { img, m, ctx in
                let shadow = colored(m, CIColor(red: 0, green: 0, blue: 0, alpha: 0.6))
                    .transformed(by: CGAffineTransform(translationX: h(ctx) * 0.03, y: -h(ctx) * 0.02))
                    .applyingGaussianBlur(sigma: h(ctx) * 0.01)
                return Segmenter.cutout(img, mask: m).composited(over: shadow.composited(over: img))
            },
            body("corps-pop", "Pop couleur") { img, m, _ in
                let pop = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.8, kCIInputContrastKey: 1.15])
                let back = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.3, kCIInputBrightnessKey: -0.1])
                return Segmenter.cutout(pop, mask: m).composited(over: back)
            },
        ]
    }
}
