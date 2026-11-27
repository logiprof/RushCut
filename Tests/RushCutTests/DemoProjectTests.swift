import Foundation
import CoreGraphics
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import RushCut

/// Crée un projet de démonstration (médias générés + montage) quand RUSHCUT_DEMO_DIR est défini.
/// Sert à la compilation automatique pour faire des captures d'écran de l'application réelle.
@Suite("Projet de démonstration")
struct DemoProjectTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUSHCUT_DEMO_DIR"] != nil))
    func createDemoProject() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUSHCUT_DEMO_DIR"]!)
        let mediaDir = root.appendingPathComponent("Médias démo", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let sunset = mediaDir.appendingPathComponent("Coucher de soleil.mov")
        try await writeScene(to: sunset, seconds: 4, night: false)
        let night = mediaDir.appendingPathComponent("Nuit étoilée.mov")
        try await writeScene(to: night, seconds: 3, night: true)
        let photo = mediaDir.appendingPathComponent("Photo.png")
        try writeGradient(to: photo, width: 1200, height: 900)
        let musicDef = SoundLibrary.byID["matin-tranquille"]!
        let music = mediaDir.appendingPathComponent("Matin tranquille.m4a")
        try SoundLibrary.write(SoundLibrary.render(musicDef), to: music)

        var project = Project()
        project.name = "Démo RushCut"
        for url in [sunset, night, photo, music] {
            project.media.append(try await MediaAnalyzer.analyze(url: url))
        }
        let ids = project.media.map(\.id)
        let a = project.addMedia(ids[0], at: nil)!
        let b = project.addMedia(ids[1], at: nil)!
        let c = project.addMedia(ids[2], at: nil)!
        project.updateClip(c) { $0.duration = RTime(seconds: 3) }
        project.updateClip(a) { clip in
            clip.filter = FilterRef(id: "cinema", intensity: 0.8)
            clip.animIn = ClipAnimation(id: AnimationCatalog.list(.entree)[0].id)
            clip.keyframes[KeyProp.scale.rawValue] = [Keyframe(time: .zero, value: 1), Keyframe(time: RTime(seconds: 4), value: 1.15)]
        }
        project.updateClip(b) { clip in
            clip.transitionIn = Transition(type: TransitionCatalog.all[0].id, duration: RTime(seconds: 0.6))
            clip.effects = [EffectInstance(type: EffectCatalog.list(.lumiere)[0].id, intensity: 0.7)]
        }
        project.updateClip(c) { clip in
            clip.transitionIn = Transition(type: TransitionCatalog.all[5].id, duration: RTime(seconds: 0.5))
            clip.animLoop = ClipAnimation(id: AnimationCatalog.list(.boucle)[0].id, duration: RTime(seconds: 1.5))
        }
        let musicClip = project.addMedia(ids[3], at: .zero)!
        project.updateClip(musicClip) { clip in
            clip.duration = RTime(seconds: 9)
            clip.audio.fadeIn = RTime(seconds: 1)
            clip.audio.fadeOut = RTime(seconds: 2)
            clip.audio.volumeDB = -6
            clip.audio.duckDB = -12
        }

        var title = TextStyleCatalog.all.first { $0.name == "Néon rose" }!.content
        title.string = "Bienvenue dans RushCut"
        title.fontSize = 0.085
        title.animation = "texte-mot-normale"
        let titleID = project.addText(title, at: RTime(seconds: 0.3), duration: RTime(seconds: 3.2))
        project.updateClip(titleID) { $0.transform.positionY = -0.18 }
        let sticker = project.addSticker(StickerCatalog.all[3].id, name: StickerCatalog.all[3].name, color: RGBA(r: 1, g: 0.85, b: 0.1), at: RTime(seconds: 4.2))
        project.updateClip(sticker) { $0.transform.positionX = 0.3; $0.transform.positionY = -0.25; $0.transform.scale = 0.7 }
        project.setSubtitles([
            SubtitleCue(start: RTime(seconds: 0.5), end: RTime(seconds: 2.5), text: "Un éditeur vidéo pour le Mac"),
            SubtitleCue(start: RTime(seconds: 2.6), end: RTime(seconds: 5.5), text: "Effets, transitions et sous-titres"),
            SubtitleCue(start: RTime(seconds: 5.6), end: RTime(seconds: 9), text: "Tout se fait sur votre ordinateur"),
        ])
        project.addMarker(at: RTime(seconds: 4))
        project.normalize(magnetic: true)

        let url = root.appendingPathComponent("Démo RushCut.rushcut")
        try? FileManager.default.removeItem(at: url)
        try ProjectStore.save(project, to: url)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
    }

    /// Petite scène animée (ciel, soleil ou étoiles, collines) pour des captures plus parlantes.
    private func writeScene(to url: URL, seconds: Double, night: Bool) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = 1280, h = 720, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let frames = Int(seconds * Double(fps))
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pb = buffer!
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let p = Double(f) / Double(frames)
            let top = night ? CGColor(srgbRed: 0.05, green: 0.05, blue: 0.2, alpha: 1) : CGColor(srgbRed: 0.2, green: 0.4, blue: 0.85, alpha: 1)
            let bottom = night ? CGColor(srgbRed: 0.4, green: 0.15, blue: 0.5, alpha: 1) : CGColor(srgbRed: 1, green: 0.6, blue: 0.3, alpha: 1)
            let gradient = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 200), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            if night {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
                for i in 0..<60 {
                    let x = CGFloat((i * 97) % w), y = CGFloat(300 + (i * 53) % 400)
                    let r = CGFloat(1.5 + 1.5 * (0.5 + 0.5 * sin(Double(i) + p * 12)))
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
                }
                ctx.fillEllipse(in: CGRect(x: 200 + 80 * p, y: 520, width: 90, height: 90))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.92, blue: 0.6, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 820, y: 260 + 160 * (1 - p), width: 160, height: 160))
            }
            ctx.setFillColor(night ? CGColor(srgbRed: 0.08, green: 0.08, blue: 0.14, alpha: 1) : CGColor(srgbRed: 0.12, green: 0.4, blue: 0.28, alpha: 1))
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: 0, y: 260))
            ctx.addCurve(to: CGPoint(x: 700, y: 210), control1: CGPoint(x: 250, y: 400), control2: CGPoint(x: 450, y: 150))
            ctx.addCurve(to: CGPoint(x: w, y: 290), control1: CGPoint(x: 950, y: 300), control2: CGPoint(x: 1150, y: 330))
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.closePath()
            ctx.fillPath()
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func writeGradient(to url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 1, green: 0.4, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.5, green: 0.1, blue: 0.6, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: width / 2 - 150, y: height / 2 - 150, width: 300, height: 300))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
