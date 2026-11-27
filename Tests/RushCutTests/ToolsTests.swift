import Foundation
import AVFoundation
import Testing
@testable import RushCut

@Suite("Outils V1", .serialized)
struct ToolsTests {
    private func importMedia(_ url: URL, into project: inout Project) async throws -> UUID {
        let media = try await MediaAnalyzer.analyze(url: url)
        project.media.append(media)
        return media.id
    }

    @Test func removeRangesClosesGaps() {
        var (p, video, _, _) = Project.sample()
        let a = p.addMedia(video, at: nil)!
        let b = p.addMedia(video, at: nil)!
        p.normalize(magnetic: true)
        let before = p.duration
        let pieces = p.removeRanges([(RTime(seconds: 2), RTime(seconds: 3)), (RTime(seconds: 6), RTime(seconds: 8))], from: a)
        p.normalize(magnetic: true)
        #expect(pieces.count == 3)
        #expect(p.duration == before - RTime(seconds: 3))
        let c = pieces.compactMap { p.clip($0) }
        #expect(c[1].sourceIn == RTime(seconds: 3))
        #expect(c[2].sourceIn == RTime(seconds: 8))
        #expect(c[2].end == p.clip(b)!.start, "Le clip suivant recolle")
    }

    @Test func zoomKeyframes() {
        var (p, video, _, _) = Project.sample()
        let a = p.addMedia(video, at: nil)!
        p.addZoom(a, at: RTime(seconds: 1), focusX: 0.25, focusY: -0.1, factor: 2)
        let clip = p.clip(a)!
        #expect(abs(clip.value(.scale, at: RTime(seconds: 2)) - 2) < 0.001)
        #expect(abs(clip.value(.positionX, at: RTime(seconds: 2)) - -0.5) < 0.001, "Le point visé passe au centre")
        #expect(abs(clip.value(.scale, at: RTime(seconds: 4)) - 1) < 0.001, "Retour à la normale")
    }

    @Test func silenceDetection() {
        // 1 s de parole, 1 s de silence, 1 s de parole (fenêtres de 20 ms).
        let levels = Array(repeating: -12.0, count: 50) + Array(repeating: -70.0, count: 50) + Array(repeating: -12.0, count: 50)
        let s = SilenceDetector.silences(levels: levels)
        #expect(s.count == 1)
        #expect(abs(s[0].0 - 1.12) < 0.001 && abs(s[0].1 - 1.88) < 0.001)
    }

    @Test func versionsAreKeptAndCapped() throws {
        let dir = TestMedia.tempDirectory().appendingPathComponent("p.rushcut")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<25 {
            ProjectStore.archiveVersion(Data("{\"i\":\(i)}".utf8), in: dir, force: true)
            Thread.sleep(forTimeInterval: 0.002)
        }
        #expect(ProjectStore.versions(of: dir).count <= ProjectStore.maxVersions)
        ProjectStore.archiveVersion(Data("{}".utf8), in: dir)
        #expect(ProjectStore.versions(of: dir).count <= ProjectStore.maxVersions, "Pas de nouvelle copie avant 5 minutes")
    }

    @Test func extraExports() async throws {
        let dir = TestMedia.tempDirectory()
        let videoURL = try await TestMedia.video(in: dir, width: 320, height: 180, seconds: 2, bgra: (0, 0, 255, 255))
        let audioURL = try TestMedia.audio(in: dir, seconds: 2)
        var project = Project()
        project.settings = ProjectSettings(width: 640, height: 360, frameRate: 30, backgroundColor: .black)
        let v = try await importMedia(videoURL, into: &project)
        let a = try await importMedia(audioURL, into: &project)
        project.addMedia(v, at: nil)
        project.addMedia(a, at: .zero)
        project.normalize(magnetic: true)

        let gif = dir.appendingPathComponent("a.gif")
        try await ExtraExporters.gif(project: project, destination: gif, start: RTime(seconds: 0.5), end: RTime(seconds: 1.5)) { _ in }
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 15)

        let still = dir.appendingPathComponent("a.png")
        try await ExtraExporters.still(project: project, at: RTime(seconds: 1), size: CGSize(width: 640, height: 360), destination: still)
        let image = try #require(CGImageSourceCreateWithURL(still as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 640)
        let px = TestMedia.pixel(image, x: 320, y: 180)
        #expect(px.r > 200 && px.g < 60, "Image rouge")

        let m4a = dir.appendingPathComponent("a.m4a")
        try await ExtraExporters.audio(project: project, destination: m4a, start: RTime(seconds: 0.5), end: RTime(seconds: 1.5))
        let d = try await AVURLAsset(url: m4a).load(.duration).seconds
        #expect(abs(d - 1) < 0.1)

        let mp4 = dir.appendingPathComponent("plage.mp4")
        var settings = ExportSettings(destination: mp4)
        settings.resolution = .p480
        settings.rangeStart = RTime(seconds: 0.5)
        settings.rangeEnd = RTime(seconds: 1.5)
        try await Exporter().run(project: project, settings: settings) { _ in }
        let vd = try await AVURLAsset(url: mp4).load(.duration).seconds
        #expect(abs(vd - 1) < 0.1, "Durée de la plage : \(vd)")
    }

    @Test func reverseVideo() async throws {
        let dir = TestMedia.tempDirectory()
        let videoURL = try await TestMedia.video(in: dir, width: 320, height: 180, seconds: 1.5, bgra: (255, 0, 0, 255))
        let out = dir.appendingPathComponent("inverse.mov")
        try await Reverser.reverseVideo(source: videoURL, start: 0.25, duration: 1, to: out) { _ in }
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(d - 1) < 0.1, "Durée : \(d)")
    }
}
