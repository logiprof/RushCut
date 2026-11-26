import Foundation
import AVFoundation
import CoreVideo

/// Écrit des vidéos simples (couleur unie). Sert à la vidéo de fond de la composition et aux médias de test.
enum VideoWriter {
    static func writeSolidColor(to url: URL, width: Int, height: Int, frames: Int, fps: Int,
                                bgra: (UInt8, UInt8, UInt8, UInt8)) async throws {
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw RushError.render("écriture vidéo impossible") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RushError.render(writer.error?.localizedDescription ?? "écriture vidéo impossible")
        }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = makeBuffer(adaptor: adaptor, width: width, height: height, bgra: bgra) else {
                throw RushError.render("mémoire vidéo indisponible")
            }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
                throw RushError.render(writer.error?.localizedDescription ?? "écriture d'image impossible")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        if writer.status != .completed {
            throw RushError.render(writer.error?.localizedDescription ?? "écriture vidéo incomplète")
        }
    }

    private static func makeBuffer(adaptor: AVAssetWriterInputPixelBufferAdaptor, width: Int, height: Int,
                                   bgra: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let rows = CVPixelBufferGetHeight(pb)
        let cols = CVPixelBufferGetWidth(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<rows {
            let row = ptr + y * rowBytes
            for x in 0..<cols {
                row[x * 4] = bgra.0
                row[x * 4 + 1] = bgra.1
                row[x * 4 + 2] = bgra.2
                row[x * 4 + 3] = bgra.3
            }
        }
        return pb
    }
}

/// Courte vidéo noire servant de « piste de fond » : elle garantit que la composition a la bonne durée
/// et que le compositeur est appelé même quand le projet ne contient que des images ou du texte.
actor BlankVideo {
    static let shared = BlankVideo()
    private var asset: AVURLAsset?

    func get() async throws -> AVURLAsset {
        if let asset { return asset }
        let url = AppPaths.caches.appendingPathComponent("fond-noir-v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = AppPaths.caches.appendingPathComponent("fond-noir-\(UUID().uuidString).mov")
            try await VideoWriter.writeSolidColor(to: tmp, width: 64, height: 64, frames: 30, fps: 30, bgra: (0, 0, 0, 255))
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.moveItem(at: tmp, to: url)
            } else {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        let a = AVURLAsset(url: url)
        asset = a
        return a
    }
}
