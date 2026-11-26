import Foundation
import AVFoundation

enum ExportContainer: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum ExportCodec: String, CaseIterable, Identifiable {
    case h264, hevc, prores422
    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264 (compatible partout)"
        case .hevc: return "HEVC (fichier plus léger)"
        case .prores422: return "ProRes 422 (archive, MOV)"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .prores422: return .proRes422
        }
    }
}

enum BitrateChoice: String, CaseIterable, Identifiable {
    case recommended, lighter, sharper, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommended: return "Recommandé"
        case .lighter: return "Plus léger"
        case .sharper: return "Plus net"
        case .custom: return "Personnalisé"
        }
    }

    var factor: Double {
        switch self {
        case .recommended, .custom: return 1
        case .lighter: return 0.6
        case .sharper: return 1.6
        }
    }
}

/// Résolutions proposées (côté le plus court), nil = taille du projet.
enum ExportResolution: Int, CaseIterable, Identifiable {
    case project = 0, p480 = 480, p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .project: return "Taille du projet"
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "2K (1440p)"
        case .p2160: return "4K (2160p)"
        }
    }
}

struct ExportSettings {
    var destination: URL
    var container: ExportContainer = .mp4
    var codec: ExportCodec = .h264
    var resolution: ExportResolution = .p1080
    var frameRate: Int = 30
    var bitrateChoice: BitrateChoice = .recommended
    var customMbps: Double = 10
    var audioBitrate: Int = 256_000

    /// Taille de sortie, en gardant les proportions du projet (dimensions paires).
    static func outputSize(project: ProjectSettings, resolution: ExportResolution) -> CGSize {
        let w = Double(project.width), h = Double(project.height)
        guard resolution != .project else { return CGSize(width: even(w), height: even(h)) }
        let short = Double(resolution.rawValue)
        if w >= h {
            return CGSize(width: even(short * w / h), height: even(short))
        } else {
            return CGSize(width: even(short), height: even(short * h / w))
        }
    }

    private static func even(_ v: Double) -> Double { max(16, (v / 2).rounded() * 2) }

    /// Débit vidéo recommandé en bits par seconde.
    static func recommendedBitrate(size: CGSize, frameRate: Int, codec: ExportCodec) -> Int {
        let short = min(size.width, size.height)
        let base: Double
        switch short {
        case ..<600: base = 2.5
        case ..<900: base = 5
        case ..<1300: base = 10
        case ..<1800: base = 16
        default: base = 35
        }
        var mbps = base * (frameRate >= 50 ? 1.5 : 1)
        if codec == .hevc { mbps *= 0.6 }
        return Int(mbps * 1_000_000)
    }

    func videoBitrate(project: ProjectSettings) -> Int {
        let size = ExportSettings.outputSize(project: project, resolution: resolution)
        if bitrateChoice == .custom { return Int(max(0.5, customMbps) * 1_000_000) }
        let rec = ExportSettings.recommendedBitrate(size: size, frameRate: frameRate, codec: codec)
        return Int(Double(rec) * bitrateChoice.factor)
    }

    /// Estimation de la taille du fichier, en octets.
    func estimatedBytes(project: ProjectSettings, duration: RTime) -> Int64 {
        let seconds = duration.seconds
        if codec == .prores422 {
            let size = ExportSettings.outputSize(project: project, resolution: resolution)
            // ProRes 422 : environ 147 Mb/s en 1080p30, proportionnel au nombre de pixels et d'images.
            let mbps = 147.0 * (size.width * size.height) / (1920 * 1080) * Double(frameRate) / 30
            return Int64(mbps * 1_000_000 / 8 * seconds)
        }
        let bits = Double(videoBitrate(project: project) + audioBitrate) * seconds
        return Int64(bits / 8 * 1.02)
    }
}

/// Export final : lit la composition (même compositeur que l'aperçu) et encode avec AVAssetWriter.
final class Exporter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Annule l'export. L'écriture est arrêtée proprement par `run`, qui supprime le fichier partiel.
    func cancel() {
        lock.lock()
        cancelled = true
        let r = reader
        lock.unlock()
        r?.cancelReading()
    }

    func run(project: Project, settings: ExportSettings,
             resolve: @escaping (MediaRef) -> URL? = MediaResolver.url(for:),
             progress: @escaping @Sendable (Double) -> Void) async throws {
        var settings = settings
        if settings.codec == .prores422 { settings.container = .mov }
        let outputSize = ExportSettings.outputSize(project: project.settings, resolution: settings.resolution)
        let built = try await CompositionBuilder.build(project: project, renderSize: outputSize,
                                                       frameRate: settings.frameRate, resolve: resolve)

        // Espace disque.
        let directory = settings.destination.deletingLastPathComponent()
        let needed = settings.estimatedBytes(project: project.settings, duration: built.duration)
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, available > 0, available < needed {
            throw RushError.notEnoughSpace(needed: needed, available: available)
        }

        let temporary = directory.appendingPathComponent(".rushcut-export-\(UUID().uuidString).\(settings.container.rawValue)")
        try? FileManager.default.removeItem(at: temporary)

        let reader = try AVAssetReader(asset: built.asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: built.duration.cmTime)
        let videoTracks = try await built.asset.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RushError.exportFailed("lecture vidéo impossible") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks = try await built.asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = built.pitchAlgorithm
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: temporary, fileType: settings.container.fileType)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if settings.codec != .prores422 {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.videoBitrate(project: project.settings),
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
            ]
            if settings.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw RushError.exportFailed("réglages vidéo refusés par l'encodeur") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let alreadyCancelled = lock.withLock { () -> Bool in
            self.reader = reader
            return cancelled
        }
        if alreadyCancelled { throw CancellationError() }

        guard reader.startReading() else {
            throw RushError.exportFailed(reader.error?.localizedDescription ?? "lecture impossible")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RushError.exportFailed(writer.error?.localizedDescription ?? "écriture impossible")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(built.duration.seconds, 0.001)
        let videoQueue = DispatchQueue(label: "ch.logiprof.rushcut.export.video")
        let audioQueue = DispatchQueue(label: "ch.logiprof.rushcut.export.audio")

        async let videoDone: Void = pump(input: videoInput, output: videoOutput, queue: videoQueue) { time in
            progress(min(1, time.seconds / total))
        }
        if let audioInput, let audioOutput {
            async let audioDone: Void = pump(input: audioInput, output: audioOutput, queue: audioQueue, onSample: nil)
            _ = await (videoDone, audioDone)
        } else {
            await videoDone
        }

        if isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporary)
            throw RushError.exportFailed(reader.error?.localizedDescription ?? "lecture interrompue")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: temporary)
            throw RushError.exportFailed(writer.error?.localizedDescription ?? "fichier incomplet")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: settings.destination.path) {
            _ = try fm.replaceItemAt(settings.destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: settings.destination)
        }
        progress(1)
        Log.info("Export terminé : \(settings.destination.path)")
    }

    private func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput, queue: DispatchQueue,
                      onSample: ((CMTime) -> Void)?) async {
        final class State: @unchecked Sendable { var finished = false }
        let state = State()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData && !state.finished {
                    if self.isCancelled {
                        state.finished = true
                        continuation.resume()
                        return
                    }
                    if let sample = output.copyNextSampleBuffer() {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if !input.append(sample) {
                            state.finished = true
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        onSample?(time)
                    } else {
                        state.finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
