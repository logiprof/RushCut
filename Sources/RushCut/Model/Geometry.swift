import Foundation
import CoreGraphics

/// Position d'un calque dans le cadre, en points du cadre, origine en haut à gauche.
/// Partagée par le compositeur (rendu) et l'aperçu (poignées) : les deux calculent exactement la même chose.
struct LayerGeometry: Equatable {
    var center: CGPoint
    var size: CGSize
    /// Degrés, sens horaire.
    var rotation: Double
    var flipH: Bool
    var flipV: Bool

    var corners: [CGPoint] {
        let hw = size.width / 2, hh = size.height / 2
        let rad = rotation * .pi / 180
        let c = cos(rad), s = sin(rad)
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { p in
            CGPoint(x: center.x + p.0 * c - p.1 * s, y: center.y + p.0 * s + p.1 * c)
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        let rad = -rotation * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        let x = dx * cos(rad) - dy * sin(rad)
        let y = dx * sin(rad) + dy * cos(rad)
        return abs(x) <= size.width / 2 && abs(y) <= size.height / 2
    }
}

enum Geometry {
    /// Taille de la source après recadrage.
    static func croppedSize(_ source: CGSize, crop: CropRect) -> CGSize {
        CGSize(width: max(1, source.width * (1 - crop.left - crop.right)),
               height: max(1, source.height * (1 - crop.top - crop.bottom)))
    }

    static func layer(sourceSize: CGSize, canvas: CGSize, fit: FitMode, transform: Transform) -> LayerGeometry {
        let sw = max(sourceSize.width, 1), sh = max(sourceSize.height, 1)
        var size: CGSize
        switch fit {
        case .fit:
            let s = min(canvas.width / sw, canvas.height / sh)
            size = CGSize(width: sw * s, height: sh * s)
        case .fill:
            let s = max(canvas.width / sw, canvas.height / sh)
            size = CGSize(width: sw * s, height: sh * s)
        case .stretch:
            size = canvas
        case .none:
            size = CGSize(width: sw, height: sh)
        }
        let scale = max(0.01, transform.scale)
        size = CGSize(width: size.width * scale, height: size.height * scale)
        let center = CGPoint(x: canvas.width / 2 + transform.positionX * canvas.width,
                             y: canvas.height / 2 + transform.positionY * canvas.height)
        return LayerGeometry(center: center, size: size, rotation: transform.rotation,
                             flipH: transform.flipH, flipV: transform.flipV)
    }

    /// Transformation à appliquer à une image Core Image (origine en bas à gauche) de taille `sourceSize`
    /// pour la placer selon `geometry` dans un cadre de hauteur `canvasHeight`.
    static func coreImageTransform(for geometry: LayerGeometry, sourceSize: CGSize, canvasHeight: CGFloat) -> CGAffineTransform {
        let sx = geometry.size.width / max(sourceSize.width, 1) * (geometry.flipH ? -1 : 1)
        let sy = geometry.size.height / max(sourceSize.height, 1) * (geometry.flipV ? -1 : 1)
        let rad = -geometry.rotation * .pi / 180
        return CGAffineTransform(translationX: -sourceSize.width / 2, y: -sourceSize.height / 2)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: rad))
            .concatenating(CGAffineTransform(translationX: geometry.center.x, y: canvasHeight - geometry.center.y))
    }

    /// Recadrage centré donnant les proportions demandées.
    static func crop(forAspect aspect: Double, source: CGSize) -> CropRect {
        let sourceAspect = source.width / max(source.height, 1)
        if aspect <= 0 { return CropRect() }
        if sourceAspect > aspect {
            let keep = aspect / sourceAspect
            let side = (1 - keep) / 2
            return CropRect(left: side, top: 0, right: side, bottom: 0)
        } else {
            let keep = sourceAspect / aspect
            let side = (1 - keep) / 2
            return CropRect(left: 0, top: side, right: 0, bottom: side)
        }
    }

    /// Ajuste une taille aux proportions d'un cadre (pour l'aperçu).
    static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: floor(size.width * s), height: floor(size.height * s))
    }
}
