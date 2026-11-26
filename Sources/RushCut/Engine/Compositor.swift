import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Contenu d'un calque à dessiner.
enum LayerContent {
    case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
    case image(url: URL, animated: Bool)
    case text(TextContent)
    case missing(name: String)
}

struct LayerPlan {
    var clipID: UUID
    var start: RTime
    var end: RTime
    var sourceIn: RTime
    var content: LayerContent
    var transform: Transform
    var crop: CropRect
    var fit: FitMode
    var opacity: Double
    var isMain: Bool
    var isHidden: Bool
}

/// Tout ce qu'il faut pour dessiner une image du projet à un instant donné.
struct RenderPlan {
    var background: RGBA
    var blurBackground: Bool
    /// Dans l'ordre de dessin (le premier est au fond).
    var layers: [LayerPlan]
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

/// Compositeur : dessine chaque image (fond, vidéos, images, textes) sur le GPU avec Core Image.
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

    // MARK: - Rendu

    static func render(plan: RenderPlan, time: RTime, renderSize: CGSize, frame: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let bg = plan.background
        var output = CIImage(color: CIColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)).cropped(to: canvas)

        let active = plan.layers.filter { !$0.isHidden && $0.start <= time && time < $0.end }

        // Fond flou : la vidéo principale agrandie et floutée derrière l'image.
        if plan.blurBackground, let main = active.first(where: { $0.isMain }),
           let source = sourceImage(for: main, time: time, renderSize: renderSize, frame: frame) {
            let cropped = applyCrop(source, crop: main.crop)
            let s = max(renderSize.width / cropped.extent.width, renderSize.height / cropped.extent.height)
            let scaled = cropped.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (renderSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x,
                y: (renderSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y))
            let blurred = centered.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(renderSize.height) * 0.035)
                .cropped(to: canvas)
            let dimmed = blurred.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08])
            output = dimmed.composited(over: output)
        }

        for layer in active {
            guard let source = sourceImage(for: layer, time: time, renderSize: renderSize, frame: frame) else { continue }
            let isText: Bool
            if case .text = layer.content { isText = true } else { isText = false }
            let cropped = isText ? source : applyCrop(source, crop: layer.crop)
            let sourceSize = cropped.extent.size
            guard sourceSize.width >= 1, sourceSize.height >= 1 else { continue }
            let geometry = Geometry.layer(sourceSize: sourceSize, canvas: renderSize,
                                          fit: isText ? .none : layer.fit, transform: layer.transform)
            var placed = cropped.transformed(by: Geometry.coreImageTransform(
                for: geometry, sourceSize: sourceSize, canvasHeight: renderSize.height))
            if layer.opacity < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, layer.opacity))),
                ])
            }
            output = placed.composited(over: output)
        }
        return output.cropped(to: canvas)
    }

    private static func sourceImage(for layer: LayerPlan, time: RTime, renderSize: CGSize,
                                    frame: (CMPersistentTrackID) -> CIImage?) -> CIImage? {
        switch layer.content {
        case .video(let trackID, let orientation):
            guard let image = frame(trackID) else { return nil }
            return normalize(image.oriented(orientation))
        case .image(let url, let animated):
            let local = (time - layer.start + layer.sourceIn).seconds
            return ImageSourceCache.shared.image(url: url, animated: animated, at: local)
        case .text(let text):
            guard let cg = TextRenderer.render(text, canvas: renderSize) else { return nil }
            return CIImage(cgImage: cg)
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

    private static func normalize(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
    }

    private static func applyCrop(_ image: CIImage, crop: CropRect) -> CIImage {
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
