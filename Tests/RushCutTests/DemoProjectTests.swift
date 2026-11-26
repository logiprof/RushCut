import Foundation
import CoreGraphics
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

        let red = try await TestMedia.video(in: mediaDir, name: "Plan rouge.mov", width: 1280, height: 720, seconds: 4, bgra: (40, 40, 220, 255))
        let blue = try await TestMedia.video(in: mediaDir, name: "Plan bleu.mov", width: 1280, height: 720, seconds: 3, bgra: (200, 120, 30, 255))
        let music = try TestMedia.audio(in: mediaDir, name: "Musique.m4a", seconds: 9)
        let photo = mediaDir.appendingPathComponent("Photo.png")
        try writeGradient(to: photo, width: 1200, height: 900)

        var project = Project()
        project.name = "Démo RushCut"
        for url in [red, blue, photo, music] {
            project.media.append(try await MediaAnalyzer.analyze(url: url))
        }
        let ids = project.media.map(\.id)
        project.addMedia(ids[0], at: nil)
        project.addMedia(ids[1], at: nil)
        project.addMedia(ids[2], at: nil)
        let musicClip = project.addMedia(ids[3], at: .zero)!
        project.updateClip(musicClip) { $0.audio.fadeIn = RTime(seconds: 1); $0.audio.fadeOut = RTime(seconds: 2); $0.audio.volumeDB = -6 }

        var title = TextContent()
        title.string = "Bienvenue dans RushCut"
        title.fontSize = 0.08
        title.shadowEnabled = true
        project.addText(title, at: RTime(seconds: 0.5), duration: RTime(seconds: 3))

        var caption = TextContent()
        caption.string = "Sous-titre sur bandeau sombre"
        caption.fontSize = 0.045
        caption.bold = false
        caption.backgroundEnabled = true
        let captionID = project.addText(caption, at: RTime(seconds: 4), duration: RTime(seconds: 3))
        project.updateClip(captionID) { $0.transform.positionY = 0.38 }
        project.addMarker(at: RTime(seconds: 4))
        project.normalize(magnetic: true)

        let url = root.appendingPathComponent("Démo RushCut.rushcut")
        try? FileManager.default.removeItem(at: url)
        try ProjectStore.save(project, to: url)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
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
