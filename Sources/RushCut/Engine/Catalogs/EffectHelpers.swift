import Foundation
import CoreImage
import CoreGraphics

enum Light {
    /// Halo coloré qui traverse l'image lentement.
    static func leak(_ i: CIImage, _ c: EffectContext, color: RGBA) -> CIImage {
        let e = i.extent
        let x = e.minX + e.width * (0.2 + 0.6 * (0.5 + 0.5 * sin(c.local * 0.7)))
        let y = e.minY + e.height * (0.7 + 0.2 * cos(c.local * 0.5))
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: x, y: y),
            "inputRadius0": 0,
            "inputRadius1": max(e.width, e.height) * 0.7,
            "inputColor0": CIColor(red: color.r, green: color.g, blue: color.b, alpha: 0.75),
            "inputColor1": CIColor(red: color.r, green: color.g, blue: color.b, alpha: 0),
        ])!.outputImage!.cropped(to: e)
        return gradient.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: i]).cropped(to: e)
    }

    static func sunbeams(_ i: CIImage, _ c: EffectContext, color: RGBA, moving: Bool) -> CIImage {
        let e = i.extent
        let x = moving ? e.minX + e.width * (0.15 + 0.7 * (0.5 + 0.5 * sin(c.local * 0.6))) : e.minX + e.width * 0.8
        let y = e.minY + e.height * 0.82
        let beams = CIFilter(name: "CISunbeamsGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: x, y: y),
            kCIInputColorKey: CI.color(color),
            "inputSunRadius": e.height * 0.04,
            "inputMaxStriationRadius": 2.6,
            "inputStriationStrength": 0.5,
            "inputStriationContrast": 1.4,
            kCIInputTimeKey: c.local.truncatingRemainder(dividingBy: 1),
        ])!.outputImage!.cropped(to: e)
        return beams.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: i]).cropped(to: e)
    }

    static func flash(_ i: CIImage, _ c: EffectContext, period: Double) -> CIImage {
        let p = c.local.truncatingRemainder(dividingBy: period) / period
        let amount = p < 0.15 ? 1 - p / 0.15 : 0
        guard amount > 0.01 else { return i }
        return i.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.5 * amount])
    }

    static func neon(_ i: CIImage, _ c: EffectContext, color: RGBA) -> CIImage {
        let edges = i.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
            .applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CI.color(color), kCIInputIntensityKey: 1])
        let glow = edges.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: c.canvas.height * 0.01, kCIInputIntensityKey: 1.5])
        let dark = i.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.25, kCIInputSaturationKey: 0.6])
        return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: dark]).cropped(to: i.extent)
    }
}

enum Blur {
    static func radialMask(_ e: CGRect, inner: CGFloat, outer: CGFloat) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: e.midX, y: e.midY),
            "inputRadius0": min(e.width, e.height) * inner,
            "inputRadius1": max(e.width, e.height) * outer,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!.cropped(to: e)
    }

    static func tiltShift(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        let top = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: e.minY + e.height * 0.62), "inputPoint1": CIVector(x: 0, y: e.minY + e.height * 0.85),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!
        let bottom = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: e.minY + e.height * 0.38), "inputPoint1": CIVector(x: 0, y: e.minY + e.height * 0.15),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!
        let mask = top.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: bottom]).cropped(to: e)
        let saturated = i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
        return saturated.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, kCIInputRadiusKey: c.canvas.height * 0.015]).cropped(to: e)
    }

    static func vignetteBlur(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        return i.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": radialMask(e, inner: 0.3, outer: 0.7), kCIInputRadiusKey: c.canvas.height * 0.02,
        ]).cropped(to: e)
    }
}

enum Glitch {
    static func channel(_ i: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    static func rgbSplit(_ i: CIImage, _ c: EffectContext, strength: Double, animated: Bool) -> CIImage {
        let e = i.extent
        var shift = c.canvas.height * 0.006 * strength
        if animated { shift *= CI.random(c.frame / 2) > 0.6 ? 2.5 : 0.6 }
        let red = channel(i, r: 1, g: 0, b: 0).transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        let green = channel(i, r: 0, g: 1, b: 0)
        let blue = channel(i, r: 0, g: 0, b: 1).transformed(by: CGAffineTransform(translationX: shift, y: 0))
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: e)
    }

    static func scanlines(_ i: CIImage, _ c: EffectContext, opacity: Double) -> CIImage {
        let e = i.extent
        let width = max(2, c.canvas.height / 270)
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0), "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: opacity),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0), kCIInputWidthKey: width, kCIInputSharpnessKey: 0.5,
        ])!.outputImage!.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: e)
        return stripes.composited(over: i).cropped(to: e)
    }

    static func vhs(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let soft = i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: c.canvas.height * 0.004, kCIInputAngleKey: 0]).cropped(to: i.extent)
        let colored = soft.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputContrastKey: 1.05])
        return CI.grain(scanlines(rgbSplit(colored, c, strength: 0.6, animated: true), c, opacity: 0.15), amount: 0.35, frame: c.frame)
    }

    static func blocks(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        var result = i
        let seed = c.frame / 3
        for k in 0..<6 where CI.random(seed, k) > 0.45 {
            let h = e.height * CGFloat(0.03 + 0.08 * CI.random(seed, k + 10))
            let y = e.minY + e.height * CGFloat(CI.random(seed, k + 20))
            let band = CGRect(x: e.minX, y: y, width: e.width, height: h)
            let dx = e.width * CGFloat(CI.random(seed, k + 30) - 0.5) * 0.12
            let piece = i.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, c.canvas.height * 0.02), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: band)
            result = piece.composited(over: result)
        }
        return result.cropped(to: e)
    }

    static func jitter(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let seed = c.frame / 2
        guard CI.random(seed) > 0.5 else { return i }
        let dx = i.extent.width * CGFloat(CI.random(seed, 4) - 0.5) * 0.04
        return i.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: i.extent)
    }

    static func bands(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        var result = i
        for k in 0..<10 {
            let y = e.minY + e.height * CGFloat(k) / 10
            let band = CGRect(x: e.minX, y: y, width: e.width, height: e.height / 10)
            let dx = e.width * CGFloat(sin(c.local * 3 + Double(k) * 1.7)) * 0.015
            result = i.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: band).composited(over: result)
        }
        return result.cropped(to: e)
    }

    static func tear(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        let seed = c.frame / 4
        let y = e.minY + e.height * CGFloat(CI.random(seed, 1))
        let upper = CGRect(x: e.minX, y: y, width: e.width, height: e.maxY - y)
        let dx = e.width * 0.05 * CGFloat(CI.random(seed, 2) - 0.5)
        return i.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: upper).composited(over: i).cropped(to: e)
    }

    static func signalLoss(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let lost = CI.random(c.frame / 5) > 0.75
        guard lost else { return i }
        let noise = CI.grain(i.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.4, kCIInputSaturationKey: 0]), amount: 1, frame: c.frame)
        return rgbSplit(noise, c, strength: 2, animated: true)
    }

    static func hologram(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let tinted = i.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CIColor(red: 0.3, green: 0.9, blue: 1), kCIInputIntensityKey: 0.85])
        let flicker = 0.85 + 0.15 * CI.random(c.frame / 2)
        let faded = tinted.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(flicker))])
        return scanlines(faded.composited(over: i.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.5])), c, opacity: 0.3)
    }
}

enum Shake {
    static func state(_ c: EffectContext, amount: Double, speed: Double) -> AnimState {
        let a = amount * c.intensity
        return AnimState(dx: a * CI.smoothNoise(c.local * speed, seed: 11), dy: a * CI.smoothNoise(c.local * speed, seed: 23),
                         scale: 1 + a * 2, rotation: a * 40 * CI.smoothNoise(c.local * speed * 0.7, seed: 37))
    }
}

enum Retro {
    static func film(_ i: CIImage, _ c: EffectContext, sepia: Double, warmth: Double) -> CIImage {
        var img = i
        if sepia > 0 { img = img.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: sepia]) }
        img = CI.temperature(img, warmth: warmth, tint: 0)
        let wobble = CI.smoothNoise(c.local * 6, seed: 5) * c.canvas.height * 0.002
        img = img.clampedToExtent().transformed(by: CGAffineTransform(translationX: 0, y: wobble)).cropped(to: i.extent)
        return CI.vignette(CI.grain(CI.fade(img, amount: 0.25), amount: 0.6, frame: c.frame), amount: 1.1)
    }

    static func scratches(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        var result = i
        let seed = c.frame / 2
        for k in 0..<3 where CI.random(seed, k) > 0.4 {
            let x = e.minX + e.width * CGFloat(CI.random(seed, k + 7))
            let line = CI.solid(RGBA(r: 1, g: 1, b: 1, a: 0.35 + 0.3 * CI.random(seed, k + 3)), CGRect(x: x, y: e.minY, width: max(1, c.canvas.height / 540), height: e.height))
            result = line.composited(over: result)
        }
        return result.cropped(to: e)
    }
}

enum Distort {
    static func bump(_ i: CIImage, _ c: EffectContext, radius: Double, scale: Double) -> CIImage {
        let e = i.extent
        return i.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: min(e.width, e.height) * radius, kCIInputScaleKey: scale,
        ]).cropped(to: e)
    }

    static func wave(_ i: CIImage, _ c: EffectContext, amplitude: Double, frequency: Double) -> CIImage {
        let e = i.extent
        var result = i
        let bands = 24
        for k in 0..<bands {
            let y = e.minY + e.height * CGFloat(k) / CGFloat(bands)
            let rect = CGRect(x: e.minX, y: y, width: e.width, height: e.height / CGFloat(bands) + 1)
            let dx = e.width * CGFloat(amplitude * sin(Double(k) / Double(bands) * frequency * 2 * .pi + c.local * 3))
            result = i.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: rect).composited(over: result)
        }
        return result.cropped(to: e)
    }

    static func mirror(_ i: CIImage, vertical: Bool) -> CIImage {
        let e = i.extent
        if vertical {
            let top = CGRect(x: e.minX, y: e.midY, width: e.width, height: e.height / 2)
            let flipped = i.cropped(to: top).transformed(by: CGAffineTransform(translationX: 0, y: e.minY + e.maxY).scaledBy(x: 1, y: -1))
            return flipped.composited(over: i).cropped(to: e)
        }
        let left = CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height)
        let flipped = i.cropped(to: left).transformed(by: CGAffineTransform(translationX: e.minX + e.maxX, y: 0).scaledBy(x: -1, y: 1))
        return flipped.composited(over: i).cropped(to: e)
    }
}

enum Tutorial {
    /// Zone visée, en coordonnées Core Image de l'image.
    static func rect(_ c: EffectContext, in e: CGRect) -> CGRect {
        let r = c.region
        return CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height, width: r.width * e.width, height: r.height * e.height)
    }

    static func ellipseMask(_ rect: CGRect, in e: CGRect, feather: CGFloat) -> CIImage {
        let radius = max(rect.width, rect.height) / 2
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY), "inputRadius0": radius * (1 - feather), "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])!.outputImage!
        let sx = rect.width / max(1, max(rect.width, rect.height)), sy = rect.height / max(1, max(rect.width, rect.height))
        return mask.transformed(by: CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))).cropped(to: e)
    }

    static func spotlight(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent
        let dark = i.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.35 * c.intensity - 0.1, kCIInputSaturationKey: 0.6])
        return i.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dark, kCIInputMaskImageKey: ellipseMask(rect(c, in: e), in: e, feather: 0.12)]).cropped(to: e)
    }

    static func magnifier(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent, r = rect(c, in: e)
        return i.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: CIVector(x: r.midX, y: r.midY), kCIInputRadiusKey: max(r.width, r.height) / 2, kCIInputScaleKey: 0.7,
        ]).cropped(to: e)
    }

    static func blurRegion(_ i: CIImage, _ c: EffectContext, pixelate: Bool) -> CIImage {
        let e = i.extent, r = rect(c, in: e)
        let processed = pixelate
            ? i.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, c.canvas.height * 0.025), kCIInputCenterKey: CIVector(x: r.midX, y: r.midY)])
            : i.clampedToExtent().applyingGaussianBlur(sigma: c.canvas.height * 0.03)
        if c.param("forme", 0) >= 1 {
            return processed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: i, kCIInputMaskImageKey: ellipseMask(r, in: e, feather: 0.05)]).cropped(to: e)
        }
        return processed.cropped(to: r).composited(over: i).cropped(to: e)
    }

    static func highlight(_ i: CIImage, _ c: EffectContext) -> CIImage {
        let e = i.extent, r = rect(c, in: e)
        let fill = CI.solid(RGBA(r: 1, g: 0.9, b: 0.1, a: 0.28), r)
        let border = max(2, c.canvas.height / 300)
        var result = fill.composited(over: i)
        for edge in [CGRect(x: r.minX, y: r.minY, width: r.width, height: border), CGRect(x: r.minX, y: r.maxY - border, width: r.width, height: border),
                     CGRect(x: r.minX, y: r.minY, width: border, height: r.height), CGRect(x: r.maxX - border, y: r.minY, width: border, height: r.height)] {
            result = CI.solid(RGBA(r: 1, g: 0.8, b: 0.1), edge).composited(over: result)
        }
        return result.cropped(to: e)
    }
}
