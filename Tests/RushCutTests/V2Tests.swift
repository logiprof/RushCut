import Foundation
import AVFoundation
import CoreImage
import Testing
@testable import RushCut

@Suite("Lot V2", .serialized)
struct V2Tests {
    private func importMedia(_ url: URL, into project: inout Project) async throws -> UUID {
        let media = try await MediaAnalyzer.analyze(url: url)
        project.media.append(media)
        return media.id
    }

    @Test func speedCurveDurationAndExport() async throws {
        let dir = TestMedia.tempDirectory()
        let url = try await TestMedia.video(in: dir, width: 320, height: 180, seconds: 4)
        var project = Project()
        project.settings = ProjectSettings(width: 640, height: 360, frameRate: 30, backgroundColor: .black)
        let id = try await importMedia(url, into: &project)
        let clip = project.addMedia(id, at: nil)!
        let preset = try #require(SpeedCurves.presets.first { $0.id == "balle" })
        project.setSpeedCurve(clip, points: preset.points, name: preset.name)
        project.normalize(magnetic: true)
        let c = try #require(project.clip(clip))
        #expect(c.duration > RTime(seconds: 4), "Le ralenti au milieu allonge le clip")
        #expect(abs(c.sourceLength.seconds - 4) < 0.05, "Toute la source est utilisée")
        let out = dir.appendingPathComponent("courbe.mp4")
        var settings = ExportSettings(destination: out)
        settings.resolution = .p480
        try await Exporter().run(project: project, settings: settings) { _ in }
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(d - c.duration.seconds) < 0.1, "Durée exportée \(d) ≈ \(c.duration.seconds)")
        // Couper rend la vitesse constante (moyenne) sans changer la durée totale.
        project.split(at: RTime(seconds: 1), clipIDs: [clip])
        #expect(project.mainClips.allSatisfy { $0.speed.curve.isEmpty })
    }

    @Test func voiceEffectsStayFinite() {
        for effect in VoiceEffects.all {
            var fx = VoiceFX(id: effect.id)
            var samples = [Float](repeating: 0, count: 9600)
            for i in 0..<9600 {
                let phase: Double = Double(i) * 2 * Double.pi * 220 / 48_000
                samples[i] = Float(sin(phase) * 0.5)
            }
            samples.withUnsafeMutableBufferPointer { fx.process($0.baseAddress!, frames: 4800) }
            #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 }, "\(effect.id)")
            #expect(samples.suffix(2000).contains { abs($0) > 0.01 }, "\(effect.id) produit du son")
        }
    }

    @Test func lutParsing() throws {
        var text = "TITLE \"Test\"\nLUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(1 - r) \(g) \(b)\n" } } }
        let (size, data) = try LUTLibrary.parse(text)
        #expect(size == 2)
        #expect(data.count == 2 * 2 * 2 * 4 * 4)
        #expect(throws: (any Error).self) { try LUTLibrary.parse("LUT_3D_SIZE 3\n0 0 0\n") }
    }

    @Test func sceneDetection() async throws {
        let dir = TestMedia.tempDirectory()
        let red = try await TestMedia.video(in: dir, name: "r.mov", width: 160, height: 90, seconds: 1.5, bgra: (0, 0, 255, 255))
        let blue = try await TestMedia.video(in: dir, name: "b.mov", width: 160, height: 90, seconds: 1.5, bgra: (255, 0, 0, 255))
        var project = Project()
        project.settings = ProjectSettings(width: 320, height: 180, frameRate: 30, backgroundColor: .black)
        let r = try await importMedia(red, into: &project)
        let b = try await importMedia(blue, into: &project)
        project.addMedia(r, at: nil)
        project.addMedia(b, at: nil)
        project.normalize(magnetic: true)
        let out = dir.appendingPathComponent("plans.mp4")
        var settings = ExportSettings(destination: out)
        settings.resolution = .p480
        try await Exporter().run(project: project, settings: settings) { _ in }
        let cuts = try await SceneDetector.cuts(url: out, start: 0, duration: 3)
        #expect(cuts.count == 1)
        #expect(abs((cuts.first ?? 0) - 1.5) < 0.2, "Coupe vers 1,5 s : \(cuts)")
    }

    @Test func beatDetection() async throws {
        // Clics à 120 bpm pendant 8 s.
        let mix = SynthMix(seconds: 8)
        let click = Synth.kick(0.15)
        for i in 0..<16 { mix.add(click, at: Double(i) * 0.5) }
        mix.finish(fadeOut: 0.01)
        let url = TestMedia.tempDirectory().appendingPathComponent("clics.m4a")
        try SoundLibrary.write(mix, to: url)
        let (bpm, beats) = try await BeatDetector.beats(url: url, start: 0, duration: 8)
        #expect(abs(bpm - 120) < 6 || abs(bpm - 60) < 3, "Tempo : \(bpm)")
        #expect(beats.count >= 7)
    }

    @Test func segmentationIsSafeWithoutPeople() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let mask = Segmenter.mask(for: image, mode: .personne, key: "test-\(UUID())", accurate: false)
        if let mask { #expect(mask.extent == image.extent) }
        let faces = Segmenter.faces(in: image, key: "test-faces-\(UUID())")
        #expect(faces.isEmpty)
        #expect(Segmenter.retouch(image, retouch: Retouch(smooth: 1, brighten: 1), faces: []).extent == image.extent)
        #expect(EffectCatalog.all.filter { $0.category == .corps }.count == 10)
    }

    @Test func templateRoundTrip() throws {
        var (p, video, _, _) = Project.sample()
        p.name = "Source"
        p.addMedia(video, at: nil)
        p.addText(TextContent(), at: .zero)
        let url = TestMedia.tempDirectory().appendingPathComponent("modele.json")
        try ProjectStore.encoder.encode(p).write(to: url)
        let made = try TemplateLibrary.project(from: url, name: "Copie")
        #expect(made.id != p.id)
        #expect(made.name == "Copie")
        #expect(made.tracks.flatMap(\.clips).count == p.tracks.flatMap(\.clips).count)
    }
}
