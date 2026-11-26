import Foundation
import CoreImage
import ImageIO

/// Images fixes et animées (GIF, PNG animé) prêtes pour le compositeur.
final class ImageSourceCache: @unchecked Sendable {
    static let shared = ImageSourceCache()

    private struct Animation {
        var frames: [CGImage]
        var ends: [Double]
        var total: Double
    }

    private var stills: [URL: CIImage] = [:]
    private var animations: [URL: Animation] = [:]
    private let lock = NSLock()

    func image(url: URL, animated: Bool, at localTime: Double) -> CIImage? {
        if animated, let frame = animationFrame(url: url, at: localTime) {
            return CIImage(cgImage: frame)
        }
        return still(url: url)
    }

    private func still(url: URL) -> CIImage? {
        lock.lock()
        if let cached = stills[url] { lock.unlock(); return cached }
        lock.unlock()
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        lock.lock()
        stills[url] = normalized
        lock.unlock()
        return normalized
    }

    private func animationFrame(url: URL, at time: Double) -> CGImage? {
        lock.lock()
        var animation = animations[url]
        lock.unlock()
        if animation == nil {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            guard count > 1 else { return nil }
            var frames: [CGImage] = []
            var ends: [Double] = []
            var t = 0.0
            for i in 0..<count {
                guard let img = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                t += MediaAnalyzer.frameDelay(source: source, index: i)
                frames.append(img)
                ends.append(t)
            }
            guard !frames.isEmpty else { return nil }
            let built = Animation(frames: frames, ends: ends, total: t)
            lock.lock()
            animations[url] = built
            lock.unlock()
            animation = built
        }
        guard let anim = animation, anim.total > 0 else { return nil }
        let local = time.truncatingRemainder(dividingBy: anim.total)
        let index = anim.ends.firstIndex { $0 > local } ?? (anim.frames.count - 1)
        return anim.frames[index]
    }

    func removeAll() {
        lock.lock()
        stills.removeAll()
        animations.removeAll()
        lock.unlock()
    }
}
