import Foundation
import AVFoundation
import CoreImage
import ImageIO
import Vision

// MARK: - Silences

enum SilenceDetector {
    struct Options {
        /// Seuil en dBFS (nil = automatique, d'après le bruit de fond).
        var thresholdDB: Double? = nil
        var minimumSilence: Double = 0.6
        /// Marge conservée autour de la parole.
        var padding: Double = 0.12
    }

    /// Niveaux (dBFS) par fenêtre de 20 ms sur une partie d'un fichier.
    static func levels(url: URL, start: Double, duration: Double) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RushError.unreadable(url.lastPathComponent) }
        let window = 320
        var levels: [Double] = []
        var acc = 0.0, n = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: bytes / 4)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            for v in samples {
                acc += Double(v * v)
                n += 1
                if n == window {
                    levels.append(10 * log10(max(acc / Double(window), 1e-10)))
                    acc = 0; n = 0
                }
            }
        }
        return levels
    }

    /// Zones de silence (en secondes depuis `start` du fichier lu), marges déduites.
    static func silences(levels: [Double], options: Options = Options()) -> [(Double, Double)] {
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let speech = sorted[Int(Double(sorted.count) * 0.9)]
        let threshold = options.thresholdDB ?? max(-55, min(speech - 18, floor + 12))
        let step = 0.02
        var result: [(Double, Double)] = []
        func append(_ a: Int, _ b: Int) {
            let start = Double(a) * step + (a == 0 ? 0 : options.padding)
            let end = Double(b) * step - (b == levels.count ? 0 : options.padding)
            if end - start >= options.minimumSilence - 2 * options.padding && end > start { result.append((start, end)) }
        }
        var runStart: Int?
        for (i, l) in levels.enumerated() {
            if l < threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                append(s, i)
                runStart = nil
            }
        }
        if let s = runStart { append(s, levels.count) }

        return result
    }
}

// MARK: - Images figées

enum FrameGrabber {
    static func image(url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

// MARK: - Lecture à l'envers

enum Reverser {
    /// Écrit la vidéo d'une partie de fichier à l'envers (sans le son), en HEVC.
    static func reverseVideo(source: URL, start: Double, duration: Double, to output: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RushError.unreadable(source.lastPathComponent) }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let frameRate = Double(fps > 0 ? fps : 30)
        let big = size.width * size.height > 2_500_000
        let chunk = big ? 0.5 : 1.0

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RushError.exportFailed("écriture impossible") }
        writer.startSession(atSourceTime: .zero)

        var outIndex: Int64 = 0
        var chunkEnd = start + duration
        while chunkEnd > start + 0.0001 {
            try Task.checkCancellation()
            let chunkStart = max(start, chunkEnd - chunk)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: chunkStart, preferredTimescale: 600), end: CMTime(seconds: chunkEnd, preferredTimescale: 600))
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(out)
            reader.startReading()
            var frames: [CVPixelBuffer] = []
            while let sample = out.copyNextSampleBuffer() {
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard t >= chunkStart - 0.0001, t < chunkEnd - 0.0001, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                frames.append(pb)
            }
            for pb in frames.reversed() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                let pts = CMTime(value: outIndex * 1000, timescale: CMTimeScale(frameRate * 1000))
                if !adaptor.append(pb, withPresentationTime: pts) { throw writer.error ?? RushError.exportFailed("écriture d'une image impossible") }
                outIndex += 1
            }
            chunkEnd = chunkStart
            progress(min(1, (start + duration - chunkEnd) / max(duration, 0.001)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RushError.exportFailed("fichier incomplet") }
    }

    /// Écrit le son d'une partie de fichier à l'envers (.caf).
    static func reverseAudio(source: URL, start: Double, duration: Double, to output: URL) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
        guard duration <= 900 else { throw RushError.exportFailed("le son à inverser dépasse 15 minutes.") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: bytes / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        let frames = samples.count / 2
        guard frames > 0 else { return false }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let ch = pcm.floatChannelData else { return false }
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let j = frames - 1 - i
            ch[0][i] = samples[2 * j]
            ch[1][i] = samples[2 * j + 1]
        }
        try file.write(from: pcm)
        file.close()
        return true
    }
}

// MARK: - Suivi de mouvement

enum MotionTracker {
    struct Point { let sourceTime: Double; let x: Double; let y: Double }

    /// Suit une zone (coordonnées normalisées, origine en haut à gauche, dans l'image redressée).
    /// Renvoie le centre de la zone suivie au fil du temps (mêmes coordonnées).
    static func track(url: URL, start: Double, duration: Double, region: CGRect,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [Point] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let transform = try await track.load(.preferredTransform)
        let orientation = CGImagePropertyOrientation(preferredTransform: transform)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: min(duration, 120), preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let handler = VNSequenceRequestHandler()
        // Vision : origine en bas à gauche.
        var observation = VNDetectedObjectObservation(boundingBox: CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height))
        var points: [Point] = []
        var lost = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            try? handler.perform([request], on: pb, orientation: orientation)
            if let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.25 {
                observation = result
                let box = result.boundingBox
                points.append(Point(sourceTime: t, x: box.midX, y: 1 - box.midY))
                lost = 0
            } else {
                lost += 1
                if lost > 10 { break }
            }
            progress(min(1, (t - start) / max(duration, 0.001)))
        }
        return points
    }
}

// MARK: - Proxys

enum ProxyStore {
    static var folder: URL { AppPaths.ensure(AppPaths.caches.appendingPathComponent("Proxys", isDirectory: true)) }

    static func url(for media: MediaRef) -> URL { folder.appendingPathComponent("\(media.id.uuidString).mp4") }

    static func existing(_ media: MediaRef) -> URL? {
        let u = url(for: media)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Vaut la peine pour les vidéos au-delà de la HD.
    static func isWorthwhile(_ media: MediaRef) -> Bool { media.kind == .video && media.width * media.height > 1920 * 1080 }

    static func create(for media: MediaRef, source: URL) async throws {
        let target = url(for: media)
        if FileManager.default.fileExists(atPath: target.path) { return }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPreset960x540) else {
            throw RushError.exportFailed("création du proxy impossible")
        }
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).mp4")
        try await session.export(to: temp, as: .mp4)
        try FileManager.default.moveItem(at: temp, to: target)
    }
}

// MARK: - Module de conversion (FFmpeg)

/// FFmpeg n'est pas livré avec RushCut : il se télécharge à la demande (une fois) depuis les compilations
/// officielles pour macOS de Martin Riedl, puis sert à convertir les formats qu'AVFoundation ne lit pas.
enum FFmpegModule {
    static var folder: URL { AppPaths.ensure(AppPaths.applicationSupport.appendingPathComponent("FFmpeg", isDirectory: true)) }
    static var binary: URL { folder.appendingPathComponent("ffmpeg") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    static var downloadURL: URL {
        #if arch(arm64)
        URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip")!
        #else
        URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip")!
        #endif
    }

    static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Téléchargement de FFmpeg…")
        let (zip, response) = try await URLSession.shared.download(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw RushError.exportFailed("téléchargement refusé par le serveur.") }
        progress("Installation…")
        let unzipDir = folder.appendingPathComponent("tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unzipDir) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipDir.path])
        let found = FileManager.default.enumerator(at: unzipDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "ffmpeg" }
        guard let found else { throw RushError.exportFailed("l'archive téléchargée ne contient pas FFmpeg.") }
        try? FileManager.default.removeItem(at: binary)
        try FileManager.default.moveItem(at: found, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        _ = try? run("/usr/bin/xattr", ["-d", "com.apple.quarantine", binary.path])
        _ = try? run("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        let version = try run(binary.path, ["-version"])
        guard version.contains("ffmpeg") else { throw RushError.exportFailed("FFmpeg ne démarre pas sur ce Mac.") }
        progress("FFmpeg est installé.")
    }

    /// Convertit un fichier vers MP4 (H.264 + AAC) ou M4A (son seul) dans `folder`.
    static func convert(_ source: URL, into outputFolder: URL) async throws -> URL {
        guard isInstalled else { throw RushError.unsupportedFormat(source.pathExtension) }
        let audioOnly = ["ogg", "oga", "opus", "wma", "amr", "ac3", "ape", "wv", "mka"].contains(source.pathExtension.lowercased())
        let base = (source.lastPathComponent as NSString).deletingPathExtension
        let output = outputFolder.appendingPathComponent("\(base) (converti).\(audioOnly ? "m4a" : "mp4")")
        let args = audioOnly
            ? ["-y", "-i", source.path, "-vn", "-c:a", "aac", "-b:a", "256k", output.path]
            : ["-y", "-i", source.path, "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", output.path]
        try await Task.detached { _ = try run(binary.path, args) }.value
        return output
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RushError.exportFailed("\(URL(fileURLWithPath: tool).lastPathComponent) : \(text.split(separator: "\n").suffix(3).joined(separator: " "))")
        }
        return text
    }
}
