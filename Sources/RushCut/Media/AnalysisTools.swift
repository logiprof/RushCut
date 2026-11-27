import Foundation
import AVFoundation
import CoreImage
import Vision

/// Lecture d'images réduites d'une partie de vidéo (pour les analyses).
enum FrameSampler {
    /// Appelle `body` pour chaque image (au plus `fps` par seconde), réduite à `width` pixels de large.
    static func sample(url: URL, start: Double, duration: Double, fps: Double, width: Int = 320,
                       body: (Double, CVPixelBuffer, CGImagePropertyOrientation) throws -> Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let orientation = CGImagePropertyOrientation(preferredTransform: transform)
        let height = max(2, Int(Double(width) * Double(size.height) / Double(max(size.width, 1))) / 2 * 2)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        reader.add(output)
        reader.startReading()
        var last = -1.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t - last >= 1 / fps - 0.0001, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            last = t
            if try !body(t, pb, orientation) { break }
        }
    }
}

// MARK: - Recadrage automatique

enum Reframer {
    /// Centre d'intérêt (x de 0 à 1, image redressée) au fil du temps : visages, sinon zone la plus saillante.
    static func subjectPath(url: URL, start: Double, duration: Double) async throws -> [(Double, Double)] {
        var path: [(Double, Double)] = []
        try await FrameSampler.sample(url: url, start: start, duration: duration, fps: 4) { t, pb, orientation in
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation)
            let faces = VNDetectFaceRectanglesRequest()
            try? handler.perform([faces])
            if let biggest = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                path.append((t, biggest.boundingBox.midX))
                return true
            }
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([saliency])
            if let box = (saliency.results?.first)?.salientObjects?.first?.boundingBox {
                path.append((t, box.midX))
            } else {
                path.append((t, path.last?.1 ?? 0.5))
            }
            return true
        }
        return smooth(path, window: 5)
    }

    static func smooth(_ path: [(Double, Double)], window: Int) -> [(Double, Double)] {
        guard path.count > 2 else { return path }
        return path.indices.map { i in
            let lo = max(0, i - window / 2), hi = min(path.count - 1, i + window / 2)
            let avg = path[lo...hi].map(\.1).reduce(0, +) / Double(hi - lo + 1)
            return (path[i].0, avg)
        }
    }
}

// MARK: - Stabilisation

enum Stabilizer {
    /// Corrections (fractions du cadre) à appliquer image par image pour lisser le tremblement.
    static func corrections(url: URL, start: Double, duration: Double, strength: Double) async throws -> [(Double, Double, Double)] {
        var raw: [(Double, Double, Double)] = []   // temps, x cumulé, y cumulé (en fraction de l'image)
        var previous: CVPixelBuffer?
        var x = 0.0, y = 0.0
        var size = CGSize(width: 320, height: 180)
        try await FrameSampler.sample(url: url, start: start, duration: duration, fps: 30) { t, pb, orientation in
            size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
            if let prev = previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pb, orientation: orientation)
                try? VNImageRequestHandler(cvPixelBuffer: prev, orientation: orientation).perform([request])
                if let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
                    x += Double(obs.alignmentTransform.tx) / Double(size.width)
                    y -= Double(obs.alignmentTransform.ty) / Double(size.height)
                }
            }
            previous = pb
            raw.append((t, x, y))
            return true
        }
        guard raw.count > 3 else { return [] }
        let window = max(5, Int(10 + 40 * strength))
        return raw.indices.map { i in
            let lo = max(0, i - window / 2), hi = min(raw.count - 1, i + window / 2)
            let n = Double(hi - lo + 1)
            let sx = raw[lo...hi].map(\.1).reduce(0, +) / n, sy = raw[lo...hi].map(\.2).reduce(0, +) / n
            return (raw[i].0, sx - raw[i].1, sy - raw[i].2)
        }
    }
}

// MARK: - Changements de plan

enum SceneDetector {
    /// Instants (secondes dans la source) où l'image change brusquement.
    static func cuts(url: URL, start: Double, duration: Double, sensitivity: Double = 0.5) async throws -> [Double] {
        var histograms: [(Double, [Double])] = []
        try await FrameSampler.sample(url: url, start: start, duration: duration, fps: 8, width: 64) { t, pb, _ in
            histograms.append((t, histogram(pb)))
            return true
        }
        guard histograms.count > 2 else { return [] }
        var diffs: [Double] = [0]
        for i in 1..<histograms.count {
            diffs.append(zip(histograms[i].1, histograms[i - 1].1).map { abs($0 - $1) }.reduce(0, +) / 2)
        }
        let threshold = 0.55 - 0.35 * sensitivity
        var cuts: [Double] = []
        for i in 1..<diffs.count where diffs[i] > threshold && diffs[i] >= (i + 1 < diffs.count ? diffs[i + 1] : 0) {
            let t = histograms[i].0
            if let last = cuts.last, t - last < 0.5 { continue }
            cuts.append(t)
        }
        return cuts
    }

    /// Histogramme couleur grossier (4×4×4), normalisé.
    static func histogram(_ pb: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var bins = [Double](repeating: 0, count: 64)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return bins }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for yy in 0..<h {
            for xx in 0..<w {
                let o = yy * row + xx * 4
                let b = Int(p[o]) >> 6, g = Int(p[o + 1]) >> 6, r = Int(p[o + 2]) >> 6
                bins[r * 16 + g * 4 + b] += 1
            }
        }
        let total = Double(w * h)
        return bins.map { $0 / max(total, 1) }
    }
}

// MARK: - Temps forts de la musique

enum BeatDetector {
    /// Instants des temps (secondes dans la source), d'après les attaques d'énergie et le tempo dominant.
    static func beats(url: URL, start: Double, duration: Double) async throws -> (bpm: Double, beats: [Double]) {
        let levels = try await SilenceDetector.levels(url: url, start: start, duration: duration)  // fenêtres de 20 ms, en dB
        guard levels.count > 50 else { return (0, []) }
        let energy = levels.map { pow(10, $0 / 10) }
        // Flux d'énergie (montées seulement).
        var flux = [Double](repeating: 0, count: energy.count)
        for i in 1..<energy.count { flux[i] = max(0, energy[i] - energy[i - 1]) }
        // Tempo : autocorrélation entre 60 et 180 bpm.
        let step = 0.02
        var best = (lag: 25, score: -1.0)
        for lag in Int(60 / 180 / step)...Int(60 / 60 / step) {
            var score = 0.0
            for i in lag..<flux.count { score += flux[i] * flux[i - lag] }
            if score > best.score { best = (lag, score) }
        }
        let period = Double(best.lag) * step
        // Phase : décalage qui aligne le mieux la grille sur les attaques.
        var bestPhase = (0, -1.0)
        for phase in 0..<best.lag {
            var s = 0.0
            var i = phase
            while i < flux.count { s += flux[i]; i += best.lag }
            if s > bestPhase.1 { bestPhase = (phase, s) }
        }
        var beats: [Double] = []
        var t = Double(bestPhase.0) * step
        while t < duration { beats.append(start + t); t += period }
        return (60 / period, beats)
    }
}

// MARK: - Ralenti fluide

enum SlowMotionRenderer {
    /// Écrit un ralenti fluide : les images intermédiaires sont des fondus des images voisines.
    static func render(source: URL, start: Double, duration: Double, rate: Double, fps: Double, to output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RushError.unreadable(source.lastPathComponent) }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RushError.exportFailed("écriture impossible") }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        var a: (Double, CIImage)?
        var b: (Double, CIImage)?
        var outIndex = 0
        let total = duration / rate
        func nextFrame() -> (Double, CIImage)? {
            guard let s = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) else { return nil }
            return (CMSampleBufferGetPresentationTimeStamp(s).seconds - start, CIImage(cvPixelBuffer: pb))
        }
        a = nextFrame()
        b = nextFrame()
        while let fa = a {
            try Task.checkCancellation()
            let tOut = Double(outIndex) / fps
            guard tOut < total else { break }
            let tSrc = tOut * rate
            while let fb = b, fb.0 <= tSrc { a = fb; b = nextFrame() }
            guard let cur = a else { break }
            var image = cur.1
            if let fb = b, fb.0 > cur.0 {
                let w = (tSrc - cur.0) / (fb.0 - cur.0)
                if w > 0.02 { image = CI.mix(cur.1, fb.1, amount: min(1, w)) }
            }
            _ = fa
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            context.render(image, to: buffer)
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(outIndex) * 1000, timescale: CMTimeScale(fps * 1000))) { break }
            outIndex += 1
            if outIndex % 15 == 0 { progress(min(1, tOut / total)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RushError.exportFailed("fichier incomplet") }
    }
}

// MARK: - LUT (.cube)

enum LUTLibrary {
    static var folder: URL { AppPaths.ensure(AppPaths.applicationSupport.appendingPathComponent("LUT", isDirectory: true)) }
    static let prefix = "lut:"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var cubes: [String: (Int, Data)] = [:]
    }
    private static let cache = Cache()

    static var installed: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".cube") }.sorted()
    }

    static func install(_ url: URL) throws -> String {
        let target = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
        _ = try parse(String(contentsOf: target, encoding: .utf8))
        return target.lastPathComponent
    }

    /// Lit un fichier .cube 3D (taille 2 à 64).
    static func parse(_ text: String) throws -> (Int, Data) {
        var size = 0
        var values: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("TITLE") || l.hasPrefix("DOMAIN") { continue }
            if l.hasPrefix("LUT_3D_SIZE") { size = Int(l.split(separator: " ").last ?? "") ?? 0; continue }
            if l.hasPrefix("LUT_1D_SIZE") { throw RushError.unsupportedFormat("cube 1D") }
            let parts = l.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 { values.append(contentsOf: parts); values.append(1) }
        }
        guard (2...64).contains(size), values.count == size * size * size * 4 else { throw RushError.unreadable("LUT .cube") }
        return (size, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    static func apply(name: String, to image: CIImage, intensity: Double) -> CIImage {
        cache.lock.lock()
        var cube = cache.cubes[name]
        cache.lock.unlock()
        if cube == nil, let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), let parsed = try? parse(text) {
            cube = parsed
            cache.lock.lock(); cache.cubes[name] = parsed; cache.lock.unlock()
        }
        guard let c = cube, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let size = c.0, data = c.1
        let graded = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size, "inputCubeData": data, "inputColorSpace": space,
        ])
        return CI.mix(image, graded, amount: intensity)
    }
}
