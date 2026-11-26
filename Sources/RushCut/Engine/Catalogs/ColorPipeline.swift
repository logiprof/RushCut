import Foundation
import CoreImage

/// Petits outils communs aux effets, filtres et transitions.
enum CI {
    static func mix(_ original: CIImage, _ processed: CIImage, amount: Double) -> CIImage {
        let a = min(max(amount, 0), 1)
        if a >= 0.999 { return processed }
        if a <= 0.001 { return original }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: processed, kCIInputTimeKey: a,
        ]).cropped(to: original.extent)
    }

    static func color(_ c: RGBA) -> CIColor { CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }

    static func solid(_ c: RGBA, _ rect: CGRect) -> CIImage { CIImage(color: color(c)).cropped(to: rect) }

    /// Nombre pseudo-aléatoire stable (0–1) : même entrée, même résultat, à l'aperçu comme à l'export.
    static func random(_ seed: Int, _ salt: Int = 0) -> Double {
        var x = UInt64(bitPattern: Int64(seed &* 73_856_093 ^ salt &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        return Double(x % 1_000_000) / 1_000_000
    }

    /// Bruit lisse (pour les tremblements de caméra).
    static func smoothNoise(_ t: Double, seed: Int) -> Double {
        let i = Int(floor(t)), f = t - floor(t)
        let a = random(i, seed) * 2 - 1, b = random(i + 1, seed) * 2 - 1
        let s = f * f * (3 - 2 * f)
        return a + (b - a) * s
    }

    static func grain(_ image: CIImage, amount: Double, frame: Int) -> CIImage {
        guard amount > 0 else { return image }
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(translationX: CGFloat(random(frame, 1) * 500), y: CGFloat(random(frame, 2) * 500)))
            .cropped(to: image.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1])
        let overlay = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.35 * amount)),
        ])
        return overlay.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: image.extent)
    }

    static func vignette(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let e = image.extent
        return image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: e.midX, y: e.midY),
            kCIInputRadiusKey: max(e.width, e.height) * 0.6,
            kCIInputIntensityKey: amount,
            "inputFalloff": 0.6,
        ]).cropped(to: e)
    }

    static func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        guard warmth != 0 || tint != 0 else { return image }
        // Une cible plus froide que la source réchauffe l'image.
        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: CGFloat(6500 - 2600 * warmth), y: CGFloat(-tint * 60)),
        ]).cropped(to: image.extent)
    }

    /// Noirs relevés (aspect « délavé »).
    static func fade(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let lift = 0.18 * amount
        return image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: CGFloat(lift)),
            "inputPoint1": CIVector(x: 0.25, y: CGFloat(0.25 + lift * 0.6)),
            "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: 0.75),
            "inputPoint4": CIVector(x: 1, y: CGFloat(1 - lift * 0.4)),
        ]).cropped(to: image.extent)
    }
}

/// Réglages de couleur d'un clip (exposition, contraste, température…).
enum ColorPipeline {
    static func apply(_ adjust: ColorAdjust, to input: CIImage, frame: Int) -> CIImage {
        guard !adjust.isNeutral else { return input }
        var image = input
        let e = input.extent
        if adjust.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjust.exposure * 2])
        }
        if adjust.brightness != 0 || adjust.contrast != 0 || adjust.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjust.brightness * 0.3,
                kCIInputContrastKey: 1 + adjust.contrast * 0.5,
                kCIInputSaturationKey: 1 + adjust.saturation,
            ])
        }
        if adjust.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": adjust.vibrance])
        }
        image = CI.temperature(image, warmth: adjust.temperature, tint: adjust.tint)
        if adjust.highlights != 0 || adjust.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - max(0, -adjust.highlights) + min(0, 0),
                "inputShadowAmount": adjust.shadows,
            ])
            if adjust.highlights > 0 {
                image = image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: CGFloat(0.75 + 0.15 * adjust.highlights)),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
            }
        }
        if adjust.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adjust.sharpness * 2])
        }
        image = image.cropped(to: e)
        image = CI.vignette(image, amount: adjust.vignette)
        image = CI.grain(image, amount: adjust.grain, frame: frame)
        return image.cropped(to: e)
    }

    /// Réglages automatiques proposés par Core Image pour une image (« Amélioration auto »).
    static func autoAdjust(for image: CIImage) -> ColorAdjust {
        var adjust = ColorAdjust()
        for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
            switch filter.name {
            case "CIVibrance":
                adjust.vibrance = min(1, max(-1, (filter.value(forKey: "inputAmount") as? Double) ?? 0))
            case "CIHighlightShadowAdjust":
                adjust.shadows = min(1, max(-1, (filter.value(forKey: "inputShadowAmount") as? Double) ?? 0))
                let h = (filter.value(forKey: "inputHighlightAmount") as? Double) ?? 1
                adjust.highlights = min(1, max(-1, h - 1))
            case "CITemperatureAndTint":
                if let neutral = filter.value(forKey: "inputNeutral") as? CIVector {
                    adjust.temperature = min(1, max(-1, (6500 - Double(neutral.x)) / -2600))
                    adjust.tint = min(1, max(-1, Double(neutral.y) / -60))
                }
            case "CIToneCurve":
                adjust.contrast = 0.15
            default:
                break
            }
        }
        if adjust.isNeutral { adjust.contrast = 0.1; adjust.vibrance = 0.15 }
        return adjust
    }
}
