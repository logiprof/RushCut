import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Contenu d'un calque à dessiner.
enum LayerContent {
    case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
    case image(url: URL, animated: Bool)
    case text(TextContent)
    case sticker(id: String, color: RGBA)
    /// Clip d'effet : s'applique à tout ce qui est dessous.
    case effect
    case missing(name: String)
}

struct LayerPlan {
    var clip: Clip
    var trackIndex: Int
    var content: LayerContent
    var isMain: Bool
    var isHidden: Bool

    var start: RTime { clip.start }
    var end: RTime { clip.end }
}

/// Tout ce qu'il faut pour dessiner une image du projet à un instant donné.
struct RenderPlan {
    var background: RGBA
    var blurBackground: Bool
    /// Dans l'ordre des pistes (la première est au fond).
    var layers: [LayerPlan]
    var fps: Int = 30
}

/// Instruction unique couvrant toute la durée : le compositeur dessine à partir du plan.
final class RushInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let plan: RenderPlan

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], plan: RenderPlan) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.plan = plan
        super.init()
    }
}

/// Compositeur : dessine chaque image (fond, vidéos, images, textes, effets, transitions) sur le GPU.
/// Le même code sert à l'aperçu et à l'export : ce que l'on voit est ce que l'on exporte.
final class RushCompositor: NSObject, AVVideoCompositing {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: RushCompositor.colorSpace,
        .outputColorSpace: RushCompositor.colorSpace,
        .cacheIntermediates: false,
    ])
    private let renderQueue = DispatchQueue(label: "ch.logiprof.rushcut.compositor", qos: .userInteractive)

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [context] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? RushInstruction else {
                    request.finish(with: RushError.render("instruction inconnue"))
                    return
                }
                guard let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: RushError.render("mémoire vidéo indisponible"))
                    return
                }
                let size = request.renderContext.size
                let time = RTime(request.compositionTime)
                let image = RushCompositor.render(plan: instruction.plan, time: time, renderSize: size) { trackID in
                    request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
                }
                context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: RushCompositor.colorSpace)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: - Rendu d'une image

    static func render(plan: RenderPlan, time: RTime, renderSize: CGSize, frame: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let frameIndex = Int(time.frameIndex(fps: plan.fps))
        var output = CI.solid(plan.background.with(alpha: 1), canvas)
        let active = plan.layers.filter { !$0.isHidden && $0.start <= time && time < $0.end }

        // Fond flou : la vidéo principale agrandie et floutée derrière l'image.
        if plan.blurBackground, let main = active.last(where: { $0.isMain }),
           let source = sourceImage(for: main, time: time, renderSize: renderSize, frame: frame) {
            let s = max(renderSize.width / source.extent.width, renderSize.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (renderSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x,
                y: (renderSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y))
            output = centered.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(renderSize.height) * 0.035)
                .cropped(to: canvas)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08])
                .composited(over: output)
        }

        // Piste principale (avec transitions).
        let mains = active.filter { $0.isMain }.sorted { $0.start < $1.start }
        if mains.count >= 2, let incoming = mains.last, let transition = incoming.clip.transitionIn {
            let outgoing = mains[mains.count - 2]
            let from = (placedLayer(outgoing, time: time, renderSize: renderSize, frame: frame, frameIndex: frameIndex)?.composited(over: output)) ?? output
            let to = (placedLayer(incoming, time: time, renderSize: renderSize, frame: frame, frameIndex: frameIndex)?.composited(over: output)) ?? output
            let progress = Double((time - incoming.start).ticks) / Double(max(1, transition.duration.ticks))
            output = TransitionCatalog.render(transition.type, from: from, to: to, progress: progress, extent: canvas, frame: frameIndex)
        } else {
            for layer in mains {
                if let placed = placedLayer(layer, time: time, renderSize: renderSize, frame: frame, frameIndex: frameIndex) {
                    output = blend(placed, over: output, mode: layer.clip.blendMode)
                }
            }
        }

        // Autres pistes, de bas en haut.
        for layer in active where !layer.isMain {
            if case .effect = layer.content {
                output = applyEffectClip(layer, to: output, time: time, renderSize: renderSize, frameIndex: frameIndex)
                continue
            }
            if let placed = placedLayer(layer, time: time, renderSize: renderSize, frame: frame, frameIndex: frameIndex) {
                output = blend(placed, over: output, mode: layer.clip.blendMode)
            }
        }
        return output.cropped(to: canvas)
    }

    static func blend(_ image: CIImage, over background: CIImage, mode: BlendMode) -> CIImage {
        let filter: String?
        switch mode {
        case .normal: filter = nil
        case .multiply: filter = "CIMultiplyBlendMode"
        case .screen: filter = "CIScreenBlendMode"
        case .overlay: filter = "CIOverlayBlendMode"
        case .softLight: filter = "CISoftLightBlendMode"
        case .darken: filter = "CIDarkenBlendMode"
        case .lighten: filter = "CILightenBlendMode"
        case .difference: filter = "CIDifferenceBlendMode"
        }
        guard let filter else { return image.composited(over: background) }
        return image.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: background]).cropped(to: background.extent)
    }

    static func effectContext(for clip: Clip, local: RTime, renderSize: CGSize, frameIndex: Int) -> EffectContext {
        var ctx = EffectContext(local: local.seconds, duration: clip.duration.seconds, frame: frameIndex, intensity: 1, params: [:], canvas: renderSize)
        // Zone visée par un effet localisé : position et échelle du clip d'effet (animables).
        let cx = 0.5 + clip.value(.positionX, at: local), cy = 0.5 + clip.value(.positionY, at: local)
        let s = clip.value(.scale, at: local)
        let w = 0.4 * s, h = 0.4 * s * Double(renderSize.width / max(1, renderSize.height))
        ctx.region = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        return ctx
    }

    private static func applyEffectClip(_ layer: LayerPlan, to image: CIImage, time: RTime, renderSize: CGSize, frameIndex: Int) -> CIImage {
        let clip = layer.clip
        let local = time - clip.start
        let ctx = effectContext(for: clip, local: local, renderSize: renderSize, frameIndex: frameIndex)
        var result = EffectCatalog.apply(clip.effects, to: image, context: ctx)
        // Mouvement de caméra appliqué à l'image entière.
        let camera = EffectCatalog.camera(clip.effects, context: ctx)
        if camera != .identity {
            let e = image.extent
            let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(scaleX: camera.scale, y: camera.scale))
                .concatenating(CGAffineTransform(rotationAngle: -camera.rotation * .pi / 180))
                .concatenating(CGAffineTransform(translationX: e.midX + camera.dx * e.width, y: e.midY - camera.dy * e.height))
            result = result.clampedToExtent().transformed(by: t).cropped(to: e)
        }
        if let filter = clip.filter { result = FilterCatalog.apply(filter, to: result, frame: frameIndex) }
        result = ColorPipeline.apply(clip.adjust, to: result, frame: frameIndex)
        return result.cropped(to: image.extent)
    }

    /// Calque prêt à composer : source traitée, placée dans le cadre (transparent ailleurs).
    static func placedLayer(_ layer: LayerPlan, time: RTime, renderSize: CGSize,
                            frame: (CMPersistentTrackID) -> CIImage?, frameIndex: Int) -> CIImage? {
        let clip = layer.clip
        let local = time - clip.start
        guard var image = sourceImage(for: layer, time: time, renderSize: renderSize, frame: frame) else { return nil }
        let isGraphic: Bool
        switch layer.content {
        case .text, .sticker: isGraphic = true
        default: isGraphic = false
        }
        var ctx = effectContext(for: clip, local: local, renderSize: renderSize, frameIndex: frameIndex)
        ctx.canvas = image.extent.size

        // Détourage, effets sur le corps et retouche du visage (Vision).
        if !isGraphic {
            let needsMask = clip.cutout != nil || clip.effects.contains { EffectCatalog.byID[$0.type]?.needsSegmentation == true }
            if needsMask {
                let key = "\(clip.id)-\(frameIndex)-\(Int(image.extent.width))"
                ctx.personMask = Segmenter.mask(for: image, mode: clip.cutout ?? .personne, key: key, accurate: renderSize.width >= 1200)
            }
            if !clip.retouch.isOff {
                let faces = Segmenter.faces(in: image, key: "\(clip.id)-\(frameIndex / 4)-\(Int(image.extent.width))")
                image = Segmenter.retouch(image, retouch: clip.retouch, faces: faces)
            }
        }

        // Traitements de l'image source.
        if !isGraphic {
            if let chroma = clip.chroma { image = ChromaKeyer.apply(chroma, to: image) }
            image = ColorPipeline.apply(clip.adjust, to: image, frame: frameIndex)
            if let filter = clip.filter { image = FilterCatalog.apply(filter, to: image, frame: frameIndex) }
        }
        if !clip.effects.isEmpty { image = EffectCatalog.apply(clip.effects, to: image, context: ctx) }
        if !isGraphic {
            if clip.cutout != nil, let m = ctx.personMask { image = Segmenter.cutout(image, mask: m) }
            if let mask = clip.mask { image = MaskRenderer.apply(mask, to: image) }
            image = applyCrop(image, crop: clip.crop)
        }
        if !clip.style.isPlain { image = LayerStyler.apply(clip.style, to: image, canvas: renderSize) }

        // Position (images clés + animations + mouvements de caméra).
        let anim = AnimationCatalog.state(for: clip, local: local).combined(with: EffectCatalog.camera(clip.effects, context: ctx))
        var transform = clip.transform
        transform.positionX = clip.value(.positionX, at: local) + anim.dx
        transform.positionY = clip.value(.positionY, at: local) + anim.dy
        transform.scale = clip.value(.scale, at: local) * anim.scale
        transform.rotation = clip.value(.rotation, at: local) + anim.rotation
        let sourceSize = image.extent.size
        guard sourceSize.width >= 1, sourceSize.height >= 1 else { return nil }
        let fit: FitMode = isGraphic ? .none : clip.fit
        let geometry = Geometry.layer(sourceSize: sourceSize, canvas: renderSize, fit: fit, transform: transform)
        var placed = image.transformed(by: Geometry.coreImageTransform(for: geometry, sourceSize: sourceSize, canvasHeight: renderSize.height))
        if anim.blur > 0.0005 {
            placed = placed.applyingGaussianBlur(sigma: anim.blur * Double(renderSize.height))
        }
        let opacity = max(0, min(1, clip.value(.opacity, at: local) * anim.opacity))
        if opacity < 0.999 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        }
        return placed.cropped(to: CGRect(origin: .zero, size: renderSize).insetBy(dx: -renderSize.width, dy: -renderSize.height))
    }

    static func sourceImage(for layer: LayerPlan, time: RTime, renderSize: CGSize,
                            frame: (CMPersistentTrackID) -> CIImage?) -> CIImage? {
        let clip = layer.clip
        let local = time - clip.start
        switch layer.content {
        case .video(let trackID, let orientation):
            guard let image = frame(trackID) else { return nil }
            return normalize(image.oriented(orientation))
        case .image(let url, let animated):
            let t = clip.sourceIn.seconds + local.seconds * clip.speed.rate
            return ImageSourceCache.shared.image(url: url, animated: animated, at: t)
        case .text(let text):
            guard let cg = TextRenderer.render(text, canvas: renderSize, local: local.seconds, clipDuration: clip.duration.seconds) else { return nil }
            return CIImage(cgImage: cg)
        case .sticker(let id, let color):
            guard let cg = StickerCatalog.render(id, color: color, canvas: renderSize) else { return nil }
            return CIImage(cgImage: cg)
        case .effect:
            return nil
        case .missing(let name):
            var placeholder = TextContent()
            placeholder.string = "Média introuvable\n\(name)"
            placeholder.fontSize = 0.04
            placeholder.backgroundEnabled = true
            placeholder.backgroundColor = RGBA(r: 0.75, g: 0.1, b: 0.1, a: 0.9)
            guard let cg = TextRenderer.render(placeholder, canvas: renderSize) else { return nil }
            return CIImage(cgImage: cg)
        }
    }

    static func normalize(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
    }

    static func applyCrop(_ image: CIImage, crop: CropRect) -> CIImage {
        guard !crop.isEmpty else { return image }
        let e = image.extent
        let rect = CGRect(x: e.origin.x + e.width * crop.left,
                          y: e.origin.y + e.height * crop.bottom,
                          width: e.width * max(0.01, 1 - crop.left - crop.right),
                          height: e.height * max(0.01, 1 - crop.top - crop.bottom))
        return normalize(image.cropped(to: rect))
    }
}

extension CGImagePropertyOrientation {
    /// Orientation d'affichage d'une piste vidéo (vidéos de téléphone tournées).
    init(preferredTransform t: CGAffineTransform) {
        let angle = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        switch angle {
        case 90: self = .right
        case -90, 270: self = .left
        case 180, -180: self = .down
        default: self = .up
        }
    }
}

/// Incrustation sur fond vert : table de couleurs qui rend transparente la couleur choisie.
enum ChromaKeyer {
    private final class Box { let data: Data; init(_ d: Data) { data = d } }
    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()
    static let size = 32

    static func apply(_ key: ChromaKey, to image: CIImage) -> CIImage {
        let id = "\(key.color.r)-\(key.color.g)-\(key.color.b)-\(key.tolerance)-\(key.softness)-\(key.spill)" as NSString
        let data: Data
        if let cached = cache.object(forKey: id) { data = cached.data } else { data = cube(key); cache.setObject(Box(data), forKey: id) }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size, "inputCubeData": data, "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ]).cropped(to: image.extent)
    }

    static func hueSat(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func cube(_ key: ChromaKey) -> Data {
        let n = size
        let target = hueSat(key.color.r, key.color.g, key.color.b)
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            let b = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let g = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let hs = hueSat(r, g, b)
                    var dh = abs(hs.h - target.h)
                    dh = min(dh, 1 - dh)
                    // Distance : teinte surtout, pondérée par la saturation (les gris ne sont jamais retirés).
                    let distance = dh * 2 + max(0, 0.25 - hs.s) * 2 + max(0, 0.15 - hs.v) * 2
                    let edge0 = key.tolerance, edge1 = key.tolerance + max(0.01, key.softness)
                    var alpha = distance <= edge0 ? 0 : (distance >= edge1 ? 1 : (distance - edge0) / (edge1 - edge0))
                    alpha = alpha * alpha * (3 - 2 * alpha)
                    var (rr, gg, bb) = (r, g, b)
                    // Débordement : réduit la couleur de fond dans les zones proches.
                    if alpha < 1 && key.spill > 0 && distance < edge1 + 0.2 {
                        let avg = (rr + gg + bb) / 3
                        let amount = key.spill * (1 - alpha)
                        rr += (avg - rr) * amount; gg += (avg - gg) * amount; bb += (avg - bb) * amount
                    }
                    values[i] = Float(rr * alpha); values[i + 1] = Float(gg * alpha); values[i + 2] = Float(bb * alpha); values[i + 3] = Float(alpha)
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Masques (linéaire, miroir, cercle, rectangle) appliqués dans l'espace de la source.
enum MaskRenderer {
    static func maskImage(_ mask: Mask, extent e: CGRect) -> CIImage {
        let cx = e.midX + CGFloat(mask.centerX) * e.width
        let cy = e.midY - CGFloat(mask.centerY) * e.height
        let w = max(1, CGFloat(mask.width) * e.width), h = max(1, CGFloat(mask.height) * e.height)
        let feather = max(0.5, CGFloat(mask.feather) * min(e.width, e.height))
        var image: CIImage
        switch mask.shape {
        case .cercle:
            image = Tutorial.ellipseMask(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), in: e, feather: min(0.9, feather / max(w, h)))
        case .rectangle:
            image = Frames.shapeMask(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), in: e,
                                     radius: CGFloat(mask.cornerRadius) * min(w, h), ellipse: false)
                .clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: e)
        case .lineaire:
            image = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy - feather), "inputPoint1": CIVector(x: cx, y: cy + feather),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])!.outputImage!.cropped(to: e.insetBy(dx: -e.width, dy: -e.height))
        case .miroir:
            let low = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy - h / 2 - feather), "inputPoint1": CIVector(x: cx, y: cy - h / 2 + feather),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
            ])!.outputImage!
            let high = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy + h / 2 - feather), "inputPoint1": CIVector(x: cx, y: cy + h / 2 + feather),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])!.outputImage!
            image = low.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: high]).cropped(to: e.insetBy(dx: -e.width, dy: -e.height))
        }
        if mask.rotation != 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: -CGFloat(mask.rotation) * .pi / 180))
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
        }
        image = image.cropped(to: e)
        if mask.invert { image = image.applyingFilter("CIColorInvert").cropped(to: e) }
        return image
    }

    static func apply(_ mask: Mask, to image: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: maskImage(mask, extent: image.extent),
        ]).cropped(to: image.extent)
    }
}

/// Coins arrondis, bordure et ombre d'un calque (incrustation).
enum LayerStyler {
    static func apply(_ style: LayerStyle, to image: CIImage, canvas: CGSize) -> CIImage {
        let e = image.extent
        var result = image
        if style.cornerRadius > 0 {
            let mask = Frames.shapeMask(e, in: e, radius: CGFloat(style.cornerRadius) * min(e.width, e.height), ellipse: false)
            result = result.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        var bounds = e
        if style.borderWidth > 0 {
            let w = CGFloat(style.borderWidth) * min(e.width, e.height)
            bounds = e.insetBy(dx: -w, dy: -w)
            let radius = style.cornerRadius > 0 ? CGFloat(style.cornerRadius) * min(e.width, e.height) + w : 0
            let border = CI.solid(style.borderColor, bounds).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: Frames.shapeMask(bounds, in: bounds, radius: radius, ellipse: false),
            ])
            result = result.composited(over: border)
        }
        if style.shadow > 0 {
            let offset = min(e.width, e.height) * 0.02
            let shadow = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.6 * style.shadow)),
            ]).applyingGaussianBlur(sigma: Double(min(e.width, e.height)) * 0.03 * style.shadow)
                .transformed(by: CGAffineTransform(translationX: offset, y: -offset))
            result = result.composited(over: shadow)
            bounds = bounds.union(shadow.extent.intersection(bounds.insetBy(dx: -offset * 4, dy: -offset * 4)))
        }
        return CompositorTools.normalized(result.cropped(to: bounds))
    }
}

enum CompositorTools {
    static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
    }
}

/// Traitement audio supplémentaire (gain au-delà de 0 dB, réduction de bruit…) : voir lot V1-C.
