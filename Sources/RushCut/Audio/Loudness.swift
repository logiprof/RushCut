import Foundation
import AVFoundation

/// Mesure de la sonie intégrée (LUFS, recommandation UIT-R BS.1770 : pondération K et fenêtres de 400 ms).
enum Loudness {
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// Filtres de pondération K pour 48 kHz.
    private static func kWeighting() -> (Biquad, Biquad) {
        (Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585),
         Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621))
    }

    /// Sonie intégrée d'un fichier (ou d'une partie), en LUFS ; nil si silencieux ou illisible.
    static func integrated(url: URL, start: Double = 0, duration: Double? = nil) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let from = CMTime(seconds: start, preferredTimescale: 48_000)
        reader.timeRange = duration.map { CMTimeRange(start: from, duration: CMTime(seconds: $0, preferredTimescale: 48_000)) }
            ?? CMTimeRange(start: from, end: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var filters = [kWeighting(), kWeighting()]
        let block = 19_200, hop = 4_800 // 400 ms, recouvrement de 75 %
        var squares: [Double] = []   // énergie pondérée par paquet de 100 ms (somme des canaux)
        var acc = 0.0, n = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(data)
            var samples = [Float](repeating: 0, count: length / 4)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < samples.count {
                var e = 0.0
                for c in 0..<2 {
                    let y = filters[c].1.run(filters[c].0.run(Double(samples[i + c])))
                    e += y * y
                }
                acc += e
                n += 1
                if n == hop { squares.append(acc / Double(hop)); acc = 0; n = 0 }
                i += 2
            }
        }
        let perBlock = block / hop
        guard squares.count >= perBlock else {
            return squares.isEmpty ? nil : loudness(squares.reduce(0, +) / Double(squares.count))
        }
        var blocks: [Double] = []
        for s in 0...(squares.count - perBlock) {
            blocks.append(squares[s..<(s + perBlock)].reduce(0, +) / Double(perBlock))
        }
        let absolute = blocks.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let threshold = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > threshold }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    private static func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-12)) }
}
