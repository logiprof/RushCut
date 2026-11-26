import Foundation
import AVFoundation
import CoreGraphics
@testable import RushCut

enum TestMedia {
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RushCutTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Vidéo de couleur unie (BGRA), sans son.
    static func video(in dir: URL, name: String = "video.mov", width: Int = 640, height: Int = 360,
                      seconds: Double = 2, fps: Int = 30, bgra: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        try await VideoWriter.writeSolidColor(to: url, width: width, height: height,
                                              frames: Int(seconds * Double(fps)), fps: fps, bgra: bgra)
        return url
    }

    /// Son sinusoïdal 440 Hz, AAC stéréo 48 kHz.
    static func audio(in dir: URL, name: String = "son.m4a", seconds: Double = 2) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try writeSine(to: url, seconds: seconds)
        return url
    }

    private static func writeSine(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let channels = Int(file.processingFormat.channelCount)
        for c in 0..<channels {
            guard let data = buffer.floatChannelData?[c] else { continue }
            for i in 0..<Int(frames) {
                data[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000) * 0.5)
            }
        }
        try file.write(from: buffer)
    }

    /// Lit la couleur d'un pixel (x, y depuis le haut à gauche) d'une image, en sRGB 0–255.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

extension Project {
    /// Projet de test avec un média vidéo de 10 s, une image et un son de 8 s (fichiers fictifs).
    static func sample() -> (Project, video: UUID, image: UUID, audio: UUID) {
        var p = Project()
        p.settings.frameRate = 30
        let video = MediaRef(name: "video.mov", path: "/tmp/inexistant-video.mov", kind: .video,
                             duration: RTime(seconds: 10), width: 1920, height: 1080, frameRate: 30, hasAudio: true)
        let image = MediaRef(name: "photo.png", path: "/tmp/inexistant-photo.png", kind: .image,
                             duration: RTime(seconds: 5), width: 1000, height: 1000)
        let audio = MediaRef(name: "musique.m4a", path: "/tmp/inexistant-musique.m4a", kind: .audio,
                             duration: RTime(seconds: 8), hasAudio: true)
        p.media = [video, image, audio]
        return (p, video.id, image.id, audio.id)
    }

    var mainClips: [Clip] { tracks[mainTrackIndex ?? 0].clips }
}
