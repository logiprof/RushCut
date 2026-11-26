import Foundation
import AVFoundation
import ImageIO
import CoreGraphics

/// Miniatures et formes d'onde, calculées en arrière-plan.
enum MediaPreviews {
    /// Vignette de bibliothèque.
    static func poster(for media: MediaRef, url: URL, maxSize: CGFloat = 320) async -> CGImage? {
        switch media.kind {
        case .image:
            return imageThumbnail(url: url, maxSize: maxSize)
        case .video:
            let generator = AVAssetImageGenerator(asset: AssetCache.shared.asset(for: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            let t = min(1.0, media.duration.seconds / 2)
            return try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        case .audio:
            return nil
        }
    }

    static func imageThumbnail(url: URL, maxSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Bande de miniatures pour la timeline : une image toutes les `interval` secondes.
    static func strip(for media: MediaRef, url: URL) async -> (images: [CGImage], interval: Double) {
        guard media.kind == .video else { return ([], 1) }
        let seconds = max(media.duration.seconds, 0.1)
        let count = min(120, max(1, Int(seconds.rounded(.up))))
        let interval = seconds / Double(count)
        let generator = AVAssetImageGenerator(asset: AssetCache.shared.asset(for: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 192)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [CGImage] = []
        for i in 0..<count {
            if Task.isCancelled { break }
            let time = CMTime(seconds: min(seconds - 0.01, (Double(i) + 0.5) * interval), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                images.append(image)
            } else if let last = images.last {
                images.append(last)
            }
        }
        return (images, interval)
    }

    /// Nombre de valeurs de forme d'onde par seconde.
    static let peaksPerSecond = 50

    /// Forme d'onde : niveau maximal (0–1) toutes les 20 ms.
    static func waveform(url: URL) async -> [Float] {
        let asset = AssetCache.shared.asset(for: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let bucket = sampleRate / peaksPerSecond
        var peaks: [Float] = []
        var currentMax: Int32 = 0
        var countInBucket = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); break }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 2 else { continue }
            var data = [Int16](repeating: 0, count: length / 2)
            let status = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for value in data {
                let a = abs(Int32(value))
                if a > currentMax { currentMax = a }
                countInBucket += 1
                if countInBucket >= bucket {
                    peaks.append(Float(currentMax) / 32_768)
                    currentMax = 0
                    countInBucket = 0
                }
            }
        }
        if countInBucket > 0 { peaks.append(Float(currentMax) / 32_768) }
        return peaks
    }
}
