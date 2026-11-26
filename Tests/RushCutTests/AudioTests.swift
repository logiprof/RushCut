import Foundation
import AVFoundation
import Testing
@testable import RushCut

enum AudioProbe {
    /// RMS du son exporté entre deux instants (mono, moyenne des canaux).
    static func rms(_ url: URL, from a: Double, to b: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 48_000), end: CMTime(seconds: b, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum = 0.0, count = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in data { sum += Double(v * v); count += 1 }
        }
        return count == 0 ? 0 : sqrt(sum / Double(count))
    }
}

@Suite("Audio", .serialized)
struct AudioTests {
    private func importMedia(_ url: URL, into project: inout Project) async throws -> UUID {
        let media = try await MediaAnalyzer.analyze(url: url)
        project.media.append(media)
        return media.id
    }

    private func export(_ project: Project, in dir: URL) async throws -> URL {
        let output = dir.appendingPathComponent("audio-\(UUID().uuidString).mp4")
        var settings = ExportSettings(destination: output)
        settings.resolution = .p720
        try await Exporter().run(project: project, settings: settings) { _ in }
        return output
    }

    @Test func gainAboveZeroDecibel() async throws {
        let dir = TestMedia.tempDirectory()
        let sine = try TestMedia.audio(in: dir, seconds: 2)
        var project = Project()
        let id = try await importMedia(sine, into: &project)
        let a = project.addMedia(id, at: .zero)!
        let b = project.addMedia(id, at: RTime(seconds: 2))!
        project.updateClip(a) { $0.audio.volumeDB = 0 }
        project.updateClip(b) { $0.audio.volumeDB = 4 }
        project.normalize(magnetic: true)
        let out = try await export(project, in: dir)
        let quiet = try await AudioProbe.rms(out, from: 0.5, to: 1.5)
        let loud = try await AudioProbe.rms(out, from: 2.5, to: 3.5)
        #expect(quiet > 0.2)
        #expect(loud / quiet > 1.4 && loud / quiet < 1.8, "+4 dB ≈ ×1,58 (mesuré : \(loud / quiet))")
    }

    @Test func duckingLowersMusic() async throws {
        let dir = TestMedia.tempDirectory()
        let music = try TestMedia.audio(in: dir, name: "musique.m4a", seconds: 4)
        let voice = try TestMedia.audio(in: dir, name: "voix.m4a", seconds: 1)
        var project = Project()
        let m = try await importMedia(music, into: &project)
        let v = try await importMedia(voice, into: &project)
        let mc = project.addMedia(m, at: .zero)!
        let vc = project.addMedia(v, at: RTime(seconds: 2))!
        project.updateClip(mc) { $0.audio.duckDB = -12 }
        project.updateClip(vc) { $0.audio.volumeDB = AudioSettings.silenceDB }
        project.normalize(magnetic: true)
        #expect(project.trackIndex(of: mc) != project.trackIndex(of: vc))
        let out = try await export(project, in: dir)
        let normal = try await AudioProbe.rms(out, from: 0.5, to: 1.5)
        let ducked = try await AudioProbe.rms(out, from: 2.4, to: 2.6)
        #expect(ducked / normal < 0.35 && ducked / normal > 0.15, "−12 dB ≈ ×0,25 (mesuré : \(ducked / normal))")
    }

    @Test func loudnessOfSine() async throws {
        let dir = TestMedia.tempDirectory()
        let sine = try TestMedia.audio(in: dir, seconds: 3)
        let lufs = try #require(await Loudness.integrated(url: sine))
        // Sinus 440 Hz d'amplitude 0,5 sur deux canaux ≈ −6,7 LUFS (à ±1,5 près selon l'AAC).
        #expect(abs(lufs - -6.7) < 1.5, "Mesuré : \(lufs)")
    }
}

@Suite("Bibliothèque de sons")
struct SoundLibraryTests {
    @Test func catalog() {
        #expect(SoundLibrary.all.filter { $0.kind == .music }.count == 10)
        #expect(SoundLibrary.all.filter { $0.kind == .effect }.count == 20)
        #expect(Set(SoundLibrary.all.map(\.id)).count == SoundLibrary.all.count)
    }

    @Test func effectsRenderAndAreAudible() {
        for def in SoundLibrary.all where def.kind == .effect {
            let mix = SoundLibrary.render(def)
            let peak = zip(mix.left, mix.right).reduce(Float(0)) { max($0, abs($1.0), abs($1.1)) }
            #expect(peak > 0.5 && peak < 0.9, "\(def.id) : crête \(peak)")
            #expect(!mix.left.contains { $0.isNaN }, "\(def.id)")
        }
    }

    @Test func musicFileIsWritten() async throws {
        let def = try #require(SoundLibrary.byID["matin-tranquille"])
        let mix = SoundLibrary.render(def)
        #expect(Double(mix.count) / Synth.sampleRate >= def.seconds)
        let url = TestMedia.tempDirectory().appendingPathComponent("musique.m4a")
        try SoundLibrary.write(mix, to: url)
        let media = try await MediaAnalyzer.analyze(url: url)
        #expect(media.kind == .audio)
        #expect(media.duration.seconds >= def.seconds)
        let lufs = try #require(await Loudness.integrated(url: url))
        #expect(lufs > -30 && lufs < -5, "Sonie : \(lufs)")
    }
}
