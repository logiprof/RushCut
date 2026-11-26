import Foundation
import AVFoundation
import Testing
@testable import RushCut

/// Tests de bout en bout : vrais fichiers, vraie composition, vrai export, lecture du fichier produit.
@Suite("Export", .serialized)
struct ExportTests {
    private func importMedia(_ url: URL, into project: inout Project) async throws -> UUID {
        let media = try await MediaAnalyzer.analyze(url: url)
        project.media.append(media)
        return media.id
    }

    @Test func analyzesMedia() async throws {
        let dir = TestMedia.tempDirectory()
        let videoURL = try await TestMedia.video(in: dir, width: 640, height: 360, seconds: 2)
        let audioURL = try TestMedia.audio(in: dir, seconds: 3)
        let video = try await MediaAnalyzer.analyze(url: videoURL)
        #expect(video.kind == .video)
        #expect(video.width == 640 && video.height == 360)
        #expect(abs(video.duration.seconds - 2) < 0.05)
        #expect(!video.hasAudio)
        let audio = try await MediaAnalyzer.analyze(url: audioURL)
        #expect(audio.kind == .audio)
        #expect(abs(audio.duration.seconds - 3) < 0.1)
    }

    @Test func rejectsUnsupportedAndCorruptFiles() async throws {
        let dir = TestMedia.tempDirectory()
        let mkv = dir.appendingPathComponent("film.mkv")
        try Data([0, 1, 2]).write(to: mkv)
        await #expect(throws: RushError.unsupportedFormat("mkv")) { try await MediaAnalyzer.analyze(url: mkv) }
        let broken = dir.appendingPathComponent("casse.mp4")
        try Data(repeating: 7, count: 2048).write(to: broken)
        await #expect(throws: RushError.self) { try await MediaAnalyzer.analyze(url: broken) }
    }

    @Test func exportMatchesProject() async throws {
        let dir = TestMedia.tempDirectory()
        // Vidéo rouge 640×360 (BGRA : bleu, vert, rouge, alpha).
        let videoURL = try await TestMedia.video(in: dir, width: 640, height: 360, seconds: 2, bgra: (0, 0, 255, 255))
        let audioURL = try TestMedia.audio(in: dir, seconds: 4)

        var project = Project()
        project.settings = ProjectSettings(width: 1920, height: 1080, frameRate: 30, backgroundColor: RGBA(r: 0, g: 0, b: 1))
        let videoID = try await importMedia(videoURL, into: &project)
        let audioID = try await importMedia(audioURL, into: &project)
        let clipA = project.addMedia(videoID, at: nil)!
        project.addMedia(videoID, at: nil)
        project.addMedia(audioID, at: .zero)
        project.updateClip(clipA) { $0.transform.scale = 0.5 }
        project.normalize(magnetic: true)
        #expect(project.duration == RTime(seconds: 4))

        let output = dir.appendingPathComponent("export.mp4")
        var settings = ExportSettings(destination: output)
        settings.resolution = .p1080
        settings.frameRate = 30
        let exporter = Exporter()
        try await exporter.run(project: project, settings: settings) { _ in }

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4) <= 1.0 / 30 + 0.01, "Durée exacte à une image près")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await videoTracks.first!.load(.naturalSize)
        #expect(size == CGSize(width: 1920, height: 1080))
        let rate = try await videoTracks.first!.load(.nominalFrameRate)
        #expect(abs(Double(rate) - 30) < 0.5)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1, "Le son est présent")

        // Premier clip réduit de moitié : rouge au centre, fond bleu dans le coin.
        let frame1 = try await TestMedia.frame(of: output, at: 1)
        let center = TestMedia.pixel(frame1, x: 960, y: 540)
        let corner = TestMedia.pixel(frame1, x: 40, y: 40)
        #expect(center.r > 180 && center.g < 80 && center.b < 80, "Centre rouge : \(center)")
        #expect(corner.b > 180 && corner.r < 80, "Coin bleu : \(corner)")
        // Deuxième clip plein cadre : rouge partout.
        let frame3 = try await TestMedia.frame(of: output, at: 3)
        let corner3 = TestMedia.pixel(frame3, x: 40, y: 40)
        #expect(corner3.r > 180 && corner3.b < 80, "Coin rouge : \(corner3)")
    }

    @Test func verticalExportKeepsProportions() async throws {
        let dir = TestMedia.tempDirectory()
        let videoURL = try await TestMedia.video(in: dir, width: 640, height: 360, seconds: 1)
        var project = Project()
        project.settings = ProjectSettings(width: 1080, height: 1920, frameRate: 30, backgroundMode: .blur)
        let id = try await importMedia(videoURL, into: &project)
        project.addMedia(id, at: nil)
        project.normalize(magnetic: true)
        let output = dir.appendingPathComponent("vertical.mp4")
        var settings = ExportSettings(destination: output)
        settings.resolution = .p720
        try await Exporter().run(project: project, settings: settings) { _ in }
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 720, height: 1280))
    }

    @Test func textOnlyProjectExports() async throws {
        let dir = TestMedia.tempDirectory()
        var project = Project()
        var text = TextContent()
        text.string = "Bonjour"
        text.backgroundEnabled = true
        text.strokeEnabled = true
        text.shadowEnabled = true
        project.addText(text, at: .zero, duration: RTime(seconds: 2))
        project.normalize(magnetic: true)
        let output = dir.appendingPathComponent("texte.mov")
        var settings = ExportSettings(destination: output)
        settings.container = .mov
        settings.codec = .hevc
        settings.resolution = .p720
        try await Exporter().run(project: project, settings: settings) { _ in }
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    @Test func missingMediaDoesNotCrash() async throws {
        let dir = TestMedia.tempDirectory()
        var (project, video, image, _) = Project.sample()
        project.addMedia(video, at: nil)
        project.addMedia(image, at: nil)
        project.normalize(magnetic: true)
        let output = dir.appendingPathComponent("manquant.mp4")
        var settings = ExportSettings(destination: output)
        settings.resolution = .p480
        try await Exporter().run(project: project, settings: settings) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func previewCompositionHasSameDuration() async throws {
        let dir = TestMedia.tempDirectory()
        let videoURL = try await TestMedia.video(in: dir, seconds: 2)
        var project = Project()
        let id = try await importMedia(videoURL, into: &project)
        project.addMedia(id, at: nil)
        project.addMedia(id, at: nil)
        project.normalize(magnetic: true)
        let built = try await CompositionBuilder.build(project: project)
        #expect(built.duration == RTime(seconds: 4))
        let duration = try await built.asset.load(.duration)
        #expect(abs(duration.seconds - 4) < 0.001)
    }

    @Test func exportCanBeCancelled() async throws {
        let dir = TestMedia.tempDirectory()
        let videoURL = try await TestMedia.video(in: dir, seconds: 2)
        var project = Project()
        let id = try await importMedia(videoURL, into: &project)
        for _ in 0..<10 { project.addMedia(id, at: nil) }
        project.normalize(magnetic: true)
        let output = dir.appendingPathComponent("annule.mp4")
        let exporter = Exporter()
        let task = Task {
            try await exporter.run(project: project, settings: ExportSettings(destination: output)) { value in
                if value > 0.05 { exporter.cancel() }
            }
        }
        do {
            try await task.value
            Issue.record("L'export aurait dû être annulé")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func sizeEstimate() {
        let settings = ExportSettings(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        let bytes = settings.estimatedBytes(project: ProjectSettings(), duration: RTime(seconds: 60))
        // 1080p30 recommandé : 10 Mb/s + 256 kb/s pendant 60 s ≈ 77 Mo.
        #expect(bytes > 70_000_000 && bytes < 85_000_000)
    }
}
