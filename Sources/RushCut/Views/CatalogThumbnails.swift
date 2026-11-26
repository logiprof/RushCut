import SwiftUI
import AppKit
import CoreImage

/// Vignettes des catalogues (effets, filtres, transitions, autocollants), calculées hors du fil principal et mises en cache.
enum CatalogThumbnails {
    static let size = CGSize(width: 192, height: 108)
    private static let queue = DispatchQueue(label: "rushcut.vignettes", qos: .userInitiated)
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private final class Box { let images: [CGImage]; init(_ i: [CGImage]) { images = i } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 800
        return c
    }()

    /// Scène d'exemple : ciel, soleil, collines et silhouette (pour que les effets se voient).
    static let sampleA: CIImage = scene(sky: (CGColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1), CGColor(red: 0.98, green: 0.62, blue: 0.35, alpha: 1)),
                                        hill: CGColor(red: 0.12, green: 0.42, blue: 0.3, alpha: 1), sun: true)
    /// Seconde scène, pour les transitions.
    static let sampleB: CIImage = scene(sky: (CGColor(red: 0.08, green: 0.06, blue: 0.25, alpha: 1), CGColor(red: 0.55, green: 0.2, blue: 0.55, alpha: 1)),
                                        hill: CGColor(red: 0.1, green: 0.1, blue: 0.16, alpha: 1), sun: false)

    private static func scene(sky: (CGColor, CGColor), hill: CGColor, sun: Bool) -> CIImage {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage(color: .gray) }
        let W = CGFloat(w), H = CGFloat(h)
        if let g = CGGradient(colorsSpace: space, colors: [sky.1, sky.0] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H * 0.3), end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if sun {
            ctx.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.6, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: W * 0.68, y: H * 0.55, width: H * 0.26, height: H * 0.26))
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.9, alpha: 0.9))
            for i in 0..<24 {
                let x = CGFloat((i * 73) % 100) / 100 * W, y = H * (0.55 + CGFloat((i * 37) % 45) / 100)
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: 3, height: 3))
            }
            ctx.fillEllipse(in: CGRect(x: W * 0.18, y: H * 0.68, width: H * 0.16, height: H * 0.16))
        }
        ctx.setFillColor(hill)
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: H * 0.38))
        ctx.addCurve(to: CGPoint(x: W * 0.55, y: H * 0.3), control1: CGPoint(x: W * 0.2, y: H * 0.58), control2: CGPoint(x: W * 0.35, y: H * 0.2))
        ctx.addCurve(to: CGPoint(x: W, y: H * 0.42), control1: CGPoint(x: W * 0.75, y: H * 0.45), control2: CGPoint(x: W * 0.9, y: H * 0.5))
        ctx.addLine(to: CGPoint(x: W, y: 0))
        ctx.closePath()
        ctx.fillPath()
        // Silhouette au centre (tête et buste).
        ctx.setFillColor(CGColor(red: 0.95, green: 0.78, blue: 0.62, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W * 0.46, y: H * 0.42, width: W * 0.08, height: W * 0.08))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.25, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: W * 0.41, y: -H * 0.05, width: W * 0.18, height: H * 0.48), cornerWidth: W * 0.06, cornerHeight: W * 0.06, transform: nil))
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return CIImage(color: .gray) }
        return CIImage(cgImage: image)
    }

    /// Calcule (ou relit) une série d'images ; `frames` = 1 pour une vignette fixe.
    static func load(_ key: String, frames: Int = 1, _ make: @escaping (Int, CIImage) -> CIImage?) async -> [CGImage] {
        let k = "\(key)#\(frames)" as NSString
        if let hit = cache.object(forKey: k) { return hit.images }
        return await withCheckedContinuation { continuation in
            queue.async {
                let base = sampleA
                var images: [CGImage] = []
                for f in 0..<frames {
                    autoreleasepool {
                        if let out = make(f, base), let cg = context.createCGImage(out.cropped(to: base.extent), from: base.extent) {
                            images.append(cg)
                        }
                    }
                }
                cache.setObject(Box(images), forKey: k)
                continuation.resume(returning: images)
            }
        }
    }

    /// Applique un état d'animation (mouvement de caméra) à une image, sur fond noir.
    static func applying(_ s: AnimState, to image: CIImage) -> CIImage {
        let e = image.extent
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
        t = t.concatenating(CGAffineTransform(scaleX: s.scale, y: s.scale))
        t = t.concatenating(CGAffineTransform(rotationAngle: -s.rotation * .pi / 180))
        t = t.concatenating(CGAffineTransform(translationX: e.midX + s.dx * e.width, y: e.midY - s.dy * e.height))
        var out = image.transformed(by: t)
        if s.blur > 0 { out = out.clampedToExtent().applyingGaussianBlur(sigma: s.blur * e.height).cropped(to: e) }
        if s.opacity < 1 { out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: s.opacity)]) }
        return out.composited(over: CIImage(color: .black).cropped(to: e))
    }

    static func effect(_ def: EffectDef, frame f: Int, frames: Int, base: CIImage) -> CIImage {
        let duration = 2.0
        let local = frames == 1 ? 0.9 : duration * Double(f) / Double(frames)
        let ctx = EffectContext(local: local, duration: duration, frame: Int(local * 30), intensity: 1, params: [:], canvas: base.extent.size)
        var image = base
        if let make = def.image { image = CI.mix(image, make(image, ctx).cropped(to: image.extent), amount: 1) }
        if let cam = def.camera { image = applying(cam(ctx), to: image) }
        return image
    }

    static func transition(_ def: TransitionDef, frame f: Int, frames: Int, base: CIImage) -> CIImage {
        let progress = frames == 1 ? 0.5 : Double(f) / Double(max(1, frames - 1))
        let b = sampleB.transformed(by: CGAffineTransform(scaleX: base.extent.width / sampleB.extent.width, y: base.extent.height / sampleB.extent.height))
        return def.render(base, b, progress, base.extent, f)
    }

    static func animation(_ def: AnimationDef, frame f: Int, frames: Int, base: CIImage) -> CIImage {
        let p = frames == 1 ? 0.5 : Double(f) / Double(max(1, frames - 1))
        let small = base.transformed(by: CGAffineTransform(scaleX: 0.6, y: 0.6))
            .transformed(by: CGAffineTransform(translationX: base.extent.width * 0.2, y: base.extent.height * 0.2))
        let framed = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(to: base.extent)
        let state = def.state(p)
        let e = base.extent
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
        t = t.concatenating(CGAffineTransform(scaleX: state.scale, y: state.scale))
        t = t.concatenating(CGAffineTransform(rotationAngle: -state.rotation * .pi / 180))
        t = t.concatenating(CGAffineTransform(translationX: e.midX + state.dx * e.width, y: e.midY - state.dy * e.height))
        var moved = small.transformed(by: t)
        if state.blur > 0 { moved = moved.applyingGaussianBlur(sigma: state.blur * e.height) }
        moved = moved.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, min(1, state.opacity)))])
        return moved.composited(over: framed)
    }
}

/// Vignette d'un élément de catalogue ; au survol, joue un aperçu animé quand `animatedFrames` > 1.
struct CatalogTile: View {
    let key: String
    let title: String
    var badge: String? = nil
    var isSelected = false
    var animatedFrames = 1
    let make: (Int, Int, CIImage) -> CIImage?
    let action: () -> Void

    @State private var still: CGImage?
    @State private var frames: [CGImage] = []
    @State private var hovering = false

    private func thumb(_ image: CGImage) -> some View {
        Image(nsImage: NSImage(cgImage: image, size: CatalogThumbnails.size))
            .resizable()
            .aspectRatio(16 / 9, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5))
                    if hovering && !frames.isEmpty {
                        TimelineView(.animation(minimumInterval: 1.0 / 12)) { tl in
                            let i = Int(tl.date.timeIntervalSinceReferenceDate * 12) % frames.count
                            thumb(frames[i])
                        }
                    } else if let still {
                        thumb(still)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .padding(3)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .task(id: key) {
            let make = self.make
            still = await CatalogThumbnails.load(key) { f, base in make(f, 1, base) }.first
        }
        .onHover { inside in
            hovering = inside
            guard inside, animatedFrames > 1, frames.isEmpty else { return }
            let make = self.make, n = animatedFrames
            Task { frames = await CatalogThumbnails.load(key, frames: n) { f, base in make(f, n, base) } }
        }
    }
}

/// Barre de catégories (puces) défilante.
struct CategoryChips: View {
    let categories: [String]
    @Binding var selected: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(categories, id: \.self) { c in
                    Button(c) { selected = c }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(selected == c ? Color.accentColor : Color.white.opacity(0.08)))
                        .foregroundStyle(selected == c ? Color.white : Color.primary)
                }
            }
            .padding(.horizontal, 10)
        }
    }
}
