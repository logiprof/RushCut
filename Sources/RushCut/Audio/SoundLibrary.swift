import Foundation
import AVFoundation

struct SoundDef: Identifiable, Sendable {
    enum Kind: String, Sendable { case music = "Musique", effect = "Effets sonores" }
    let id: String
    let name: String
    let kind: Kind
    let mood: String
    let seconds: Double
    var bpm: Int? = nil
}

/// Bibliothèque de musiques et de bruitages originaux, générés par RushCut lui-même.
/// Libres de droits : utilisables dans toutes les vidéos, y compris commerciales et monétisées.
enum SoundLibrary {
    /// Incrémenté quand les recettes changent (les fichiers en cache sont alors recréés).
    static let recipeVersion = 1

    static let all: [SoundDef] = [
        SoundDef(id: "matin-tranquille", name: "Matin tranquille", kind: .music, mood: "Lo-fi, calme", seconds: 38.4, bpm: 75),
        SoundDef(id: "energie-positive", name: "Énergie positive", kind: .music, mood: "Pop, entraînant", seconds: 32, bpm: 120),
        SoundDef(id: "horizon", name: "Horizon", kind: .music, mood: "Cinématique, inspirant", seconds: 41.1, bpm: 70),
        SoundDef(id: "neon-nocturne", name: "Néon nocturne", kind: .music, mood: "Synthwave, rétro", seconds: 38.4, bpm: 100),
        SoundDef(id: "startup", name: "Start-up", kind: .music, mood: "Entreprise, optimiste", seconds: 34.9, bpm: 110),
        SoundDef(id: "feu-de-camp", name: "Feu de camp", kind: .music, mood: "Acoustique, chaleureux", seconds: 40.4, bpm: 95),
        SoundDef(id: "suspense", name: "Suspense", kind: .music, mood: "Tendu, mystérieux", seconds: 32, bpm: 60),
        SoundDef(id: "fete", name: "La fête", kind: .music, mood: "House, dansant", seconds: 30, bpm: 128),
        SoundDef(id: "reverie", name: "Rêverie", kind: .music, mood: "Ambiance, doux", seconds: 36, bpm: 80),
        SoundDef(id: "rue", name: "Dans la rue", kind: .music, mood: "Hip-hop, cool", seconds: 42.7, bpm: 90),

        SoundDef(id: "whoosh", name: "Whoosh", kind: .effect, mood: "Transition", seconds: 0.7),
        SoundDef(id: "swoosh-court", name: "Swoosh court", kind: .effect, mood: "Transition", seconds: 0.35),
        SoundDef(id: "montee", name: "Montée", kind: .effect, mood: "Transition", seconds: 2.5),
        SoundDef(id: "impact", name: "Impact", kind: .effect, mood: "Transition", seconds: 1.8),
        SoundDef(id: "pop", name: "Pop", kind: .effect, mood: "Interface", seconds: 0.25),
        SoundDef(id: "clic", name: "Clic", kind: .effect, mood: "Interface", seconds: 0.12),
        SoundDef(id: "ding", name: "Ding", kind: .effect, mood: "Interface", seconds: 1.5),
        SoundDef(id: "notification", name: "Notification", kind: .effect, mood: "Interface", seconds: 0.8),
        SoundDef(id: "succes", name: "Succès", kind: .effect, mood: "Interface", seconds: 1.4),
        SoundDef(id: "erreur", name: "Erreur", kind: .effect, mood: "Interface", seconds: 0.6),
        SoundDef(id: "bip-censure", name: "Bip de censure", kind: .effect, mood: "Humour", seconds: 0.8),
        SoundDef(id: "caisse", name: "Tiroir-caisse", kind: .effect, mood: "Humour", seconds: 1.2),
        SoundDef(id: "roulement", name: "Roulement de tambour", kind: .effect, mood: "Humour", seconds: 2.6),
        SoundDef(id: "ba-dum-tss", name: "Ba-dum-tss", kind: .effect, mood: "Humour", seconds: 1.4),
        SoundDef(id: "applaudissements", name: "Applaudissements", kind: .effect, mood: "Ambiance", seconds: 4),
        SoundDef(id: "battement", name: "Battement de cœur", kind: .effect, mood: "Ambiance", seconds: 3.2),
        SoundDef(id: "tic-tac", name: "Tic-tac", kind: .effect, mood: "Ambiance", seconds: 4),
        SoundDef(id: "machine-a-ecrire", name: "Machine à écrire", kind: .effect, mood: "Ambiance", seconds: 2.4),
        SoundDef(id: "glitch", name: "Glitch", kind: .effect, mood: "Transition", seconds: 0.6),
        SoundDef(id: "magie", name: "Magie", kind: .effect, mood: "Ambiance", seconds: 2),
    ]

    static let byID: [String: SoundDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static var folder: URL { AppPaths.ensure(AppPaths.applicationSupport.appendingPathComponent("Sons", isDirectory: true)) }

    static func cachedURL(_ def: SoundDef) -> URL { folder.appendingPathComponent("\(def.id)-v\(recipeVersion).m4a") }

    /// Fichier du son (créé à la première demande, puis réutilisé).
    static func file(for def: SoundDef) async throws -> URL {
        let url = cachedURL(def)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return try await Task.detached(priority: .userInitiated) {
            let mix = render(def)
            try write(mix, to: url)
            return url
        }.value
    }

    static func write(_ mix: SynthMix, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 44_100
            var offset = 0
            while offset < mix.count {
                let n = min(chunk, mix.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                      let data = buffer.floatChannelData else { break }
                buffer.frameLength = AVAudioFrameCount(n)
                for i in 0..<n {
                    data[0][i] = mix.left[offset + i]
                    data[1][i] = mix.right[offset + i]
                }
                try file.write(from: buffer)
                offset += n
            }
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    // MARK: - Recettes

    static func render(_ def: SoundDef) -> SynthMix {
        switch def.id {
        case "matin-tranquille": return lofi(def)
        case "energie-positive": return pop(def)
        case "horizon": return cinematic(def)
        case "neon-nocturne": return synthwave(def)
        case "startup": return corporate(def)
        case "feu-de-camp": return acoustic(def)
        case "suspense": return suspense(def)
        case "fete": return house(def)
        case "reverie": return ambient(def)
        case "rue": return hiphop(def)
        default: return effect(def)
        }
    }

    /// Accords (notes MIDI) d'une progression, un par mesure.
    private static func chords(_ root: Int, _ degrees: [[Int]]) -> [[Int]] { degrees.map { $0.map { root + $0 } } }
    private static let major = [0, 4, 7], minor = [0, 3, 7], major7 = [0, 4, 7, 11], minor7 = [0, 3, 7, 10]
    private static func shift(_ c: [Int], _ by: Int) -> [Int] { c.map { $0 + by } }

    private static func drums(_ mix: SynthMix, beat: Double, bars: Int, kick: [Double], snare: [Double], hats: Int,
                              swing: Double = 0, gain: Float = 1, skipFirstBar: Bool = false) {
        let k = Synth.kick(), s = Synth.snare(), h = Synth.hat()
        for bar in 0..<bars where !(skipFirstBar && bar == 0) {
            let t0 = Double(bar) * 4 * beat
            for b in kick { mix.add(k, at: t0 + b * beat, gain: 0.9 * gain) }
            for b in snare { mix.add(s, at: t0 + b * beat, gain: 0.55 * gain) }
            if hats > 0 {
                for i in 0..<(4 * hats) {
                    let off = i % 2 == 1 ? swing * beat / Double(hats) : 0
                    mix.add(h, at: t0 + Double(i) * beat / Double(hats) + off, gain: (i % 2 == 0 ? 0.5 : 0.32) * gain, pan: 0.25)
                }
            }
        }
    }

    private static func lofi(_ def: SoundDef) -> SynthMix {
        let beat = 60.0 / 75, bars = 12
        let mix = SynthMix(seconds: def.seconds + 1)
        let prog = chords(57, [major7, shift(minor7, 5), shift(minor7, 2), shift(major7, 7)]) // la ré si mi
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for (i, n) in c.enumerated() { mix.add(Synth.epiano(Synth.midi(n), 4 * beat * 0.95), at: t + Double(i) * 0.012, gain: 0.22, pan: Float(i) * 0.2 - 0.3) }
            mix.add(Synth.tone(Synth.midi(c[0] - 24), 1.6 * beat, wave: .sine, attack: 0.01, decay: 0.3, sustain: 0.8, release: 0.1), at: t, gain: 0.5)
            mix.add(Synth.tone(Synth.midi(c[0] - 24 + 7), 0.9 * beat, wave: .sine, attack: 0.01, decay: 0.3, sustain: 0.8, release: 0.1), at: t + 2.5 * beat, gain: 0.4)
        }
        drums(mix, beat: beat, bars: bars, kick: [0, 2.5], snare: [1, 3], hats: 2, swing: 0.18, gain: 0.7, skipFirstBar: true)
        var rng = Synth.Random(3)
        let crackle = Synth.hat(seed: 99)
        var t = 0.0
        while t < def.seconds { mix.add(crackle, at: t, gain: 0.08 * Float(rng.unit()), pan: rng.next()); t += 0.05 + rng.unit() * 0.4 }
        mix.reverb(amount: 0.5)
        mix.finish(fadeOut: 2)
        return mix
    }

    private static func pop(_ def: SoundDef) -> SynthMix {
        let beat = 0.5, bars = 16
        let mix = SynthMix(seconds: def.seconds + 1)
        let prog = chords(60, [major, shift(major, 7), shift(minor, 9), shift(major, 5)])
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for step in 0..<8 where step != 3 && step != 7 {
                for n in c { mix.add(Synth.tone(Synth.midi(n + 12), 0.18, wave: .saw, voices: 2, attack: 0.003, decay: 0.12, sustain: 0.2, release: 0.08, cutoff: 1800, cutoffEnv: 1.5), at: t + Double(step) * beat / 2, gain: 0.1, pan: Float(n % 3) * 0.3 - 0.3) }
            }
            for step in 0..<8 {
                let n = c[0] - 12 + (step % 4 == 3 ? 7 : 0)
                mix.add(Synth.tone(Synth.midi(n), 0.2, wave: .square, attack: 0.005, decay: 0.1, sustain: 0.6, release: 0.05, cutoff: 600), at: t + Double(step) * beat / 2, gain: 0.32)
            }
            if bar >= 4 {
                let melody = [0, 2, 4, 7, 4, 2, 0, -1]
                for (i, d) in melody.enumerated() where (i + bar) % 3 != 2 {
                    mix.add(Synth.bell(Synth.midi(c[0] + 24 + d), 0.6), at: t + Double(i) * beat / 2, gain: 0.18, pan: 0.2)
                }
            }
        }
        drums(mix, beat: beat, bars: bars, kick: [0, 1, 2, 3], snare: [1, 3], hats: 2)
        let clap = Synth.clap()
        for bar in 0..<bars { for b in [1.0, 3.0] { mix.add(clap, at: Double(bar) * 4 * beat + b * beat, gain: 0.35) } }
        mix.reverb(amount: 0.3)
        mix.finish(fadeOut: 1.5)
        return mix
    }

    private static func cinematic(_ def: SoundDef) -> SynthMix {
        let beat = 60.0 / 70, bars = 12
        let mix = SynthMix(seconds: def.seconds + 2)
        let prog = chords(50, [minor, shift(major, -4), shift(major, -7), shift(major, -2)]) // ré si♭ sol do
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for n in c + [c[0] + 12] {
                mix.add(Synth.tone(Synth.midi(n), 4 * beat, wave: .saw, voices: 3, detune: 0.12, attack: 1.2, decay: 1, sustain: 0.8, release: 1.5, cutoff: 900 + Double(bar) * 80), at: t, gain: 0.09, pan: Float(n % 5) * 0.2 - 0.4)
            }
            mix.add(Synth.tone(Synth.midi(c[0] - 12), 4 * beat, wave: .sine, attack: 0.5, decay: 1, sustain: 0.9, release: 1), at: t, gain: 0.35)
            if bar >= 4 {
                for i in 0..<4 { mix.add(Synth.pluck(Synth.midi(c[i % 3] + 24), 2.5, brightness: 0.7, seed: UInt64(bar * 4 + i)), at: t + Double(i) * beat, gain: 0.35, pan: 0.3) }
            }
            if bar >= 8 || bar % 4 == 3 { mix.add(Synth.kick(1.2, punch: 0.6), at: t, gain: 0.8) }
        }
        mix.reverb(amount: 0.9, size: 1.3)
        mix.finish(fadeOut: 3)
        return mix
    }

    private static func synthwave(_ def: SoundDef) -> SynthMix {
        let beat = 0.6, bars = 16
        let mix = SynthMix(seconds: def.seconds + 1)
        let prog = chords(57, [minor, shift(major, -4), shift(major, -9), shift(major, -2)])
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for i in 0..<16 {
                let n = c[i % 3] + 12 + (i % 8 >= 6 ? 12 : 0)
                mix.add(Synth.tone(Synth.midi(n), 0.12, wave: .saw, attack: 0.002, decay: 0.1, sustain: 0.3, release: 0.1, cutoff: 1200, cutoffEnv: 2), at: t + Double(i) * beat / 4, gain: 0.12, pan: i % 2 == 0 ? -0.4 : 0.4)
            }
            for i in 0..<8 {
                mix.add(Synth.tone(Synth.midi(c[0] - 24 + (i % 2 == 1 ? 12 : 0)), 0.25, wave: .saw, attack: 0.003, decay: 0.15, sustain: 0.5, release: 0.05, cutoff: 500, cutoffEnv: 1), at: t + Double(i) * beat / 2, gain: 0.3)
            }
            for n in c { mix.add(Synth.tone(Synth.midi(n), 4 * beat, wave: .square, voices: 2, attack: 0.4, decay: 0.5, sustain: 0.6, release: 0.6, cutoff: 700), at: t, gain: 0.06) }
        }
        drums(mix, beat: beat, bars: bars, kick: [0, 2], snare: [1, 3], hats: 2, skipFirstBar: true)
        mix.reverb(amount: 0.6)
        mix.finish(fadeOut: 2)
        return mix
    }

    private static func corporate(_ def: SoundDef) -> SynthMix {
        let beat = 60.0 / 110, bars = 16
        let mix = SynthMix(seconds: def.seconds + 1)
        let prog = chords(62, [major, shift(major, 5), shift(minor, 9), shift(major, 7)])
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            let pattern = [0, 2, 1, 2, 0, 2, 1, 2]
            for (i, idx) in pattern.enumerated() { mix.add(Synth.marimba(Synth.midi(c[idx] + 12)), at: t + Double(i) * beat / 2, gain: 0.35, pan: Float(idx) * 0.3 - 0.3) }
            for n in c { mix.add(Synth.tone(Synth.midi(n), 4 * beat, wave: .triangle, voices: 2, attack: 0.3, decay: 0.5, sustain: 0.7, release: 0.5, cutoff: 2000), at: t, gain: 0.08) }
            mix.add(Synth.tone(Synth.midi(c[0] - 24), 3.5 * beat, wave: .sine, attack: 0.02, decay: 0.5, sustain: 0.8, release: 0.3), at: t, gain: 0.35)
        }
        drums(mix, beat: beat, bars: bars, kick: [0, 2], snare: [1, 3], hats: 4, gain: 0.6, skipFirstBar: true)
        mix.reverb(amount: 0.4)
        mix.finish(fadeOut: 2)
        return mix
    }

    private static func acoustic(_ def: SoundDef) -> SynthMix {
        let beat = 60.0 / 95, bars = 16
        let mix = SynthMix(seconds: def.seconds + 2)
        let prog = chords(55, [major, shift(major, 7), shift(minor, 9), shift(major, 5)]) // sol ré mi- do
        let strum: [(Double, Bool)] = [(0, true), (1, true), (1.5, false), (2.5, false), (3, true), (3.5, false)]
        for bar in 0..<bars {
            let c = prog[bar % 4] + [prog[bar % 4][0] + 12, prog[bar % 4][1] + 12]
            let t = Double(bar) * 4 * beat
            for (b, down) in strum {
                let notes = down ? c : c.reversed()
                for (i, n) in notes.enumerated() {
                    mix.add(Synth.pluck(Synth.midi(n - 12), 1.6, brightness: down ? 0.6 : 0.4, seed: UInt64(bar * 50 + Int(b * 10) + i)), at: t + b * beat + Double(i) * 0.012, gain: down ? 0.22 : 0.15, pan: Float(i) * 0.12 - 0.3)
                }
            }
            mix.add(Synth.pluck(Synth.midi(c[0] - 24), 2.2, brightness: 0.3, seed: UInt64(bar)), at: t, gain: 0.45)
        }
        let shaker = Synth.hat(seed: 31)
        for i in 0..<(bars * 8) { mix.add(shaker, at: Double(i) * beat / 2, gain: i % 2 == 0 ? 0.25 : 0.4, pan: 0.4) }
        mix.reverb(amount: 0.45)
        mix.finish(fadeOut: 2.5)
        return mix
    }

    private static func suspense(_ def: SoundDef) -> SynthMix {
        let beat = 1.0, bars = 8
        let mix = SynthMix(seconds: def.seconds + 2)
        mix.add(Synth.tone(Synth.midi(38), def.seconds, wave: .saw, voices: 3, detune: 0.2, attack: 3, decay: 1, sustain: 1, release: 2, cutoff: 260, vibrato: 0.002), at: 0, gain: 0.35)
        mix.add(Synth.tone(Synth.midi(45), def.seconds - 8, wave: .sine, attack: 4, decay: 1, sustain: 1, release: 2, vibrato: 0.004), at: 8, gain: 0.12)
        let tick = Synth.hat(seed: 5)
        for i in 0..<Int(def.seconds * 2) { mix.add(tick, at: Double(i) * beat / 2, gain: i % 2 == 0 ? 0.5 : 0.25, pan: i % 2 == 0 ? -0.3 : 0.3) }
        for bar in 0..<bars where bar % 2 == 1 { mix.add(Synth.kick(1.5, punch: 0.4), at: Double(bar) * 4 * beat, gain: 0.7) }
        for (i, n) in [62, 63, 62, 66].enumerated() { mix.add(Synth.bell(Synth.midi(n + 12), 3, decay: 2), at: 12 + Double(i) * 4, gain: 0.12, pan: 0.3) }
        mix.reverb(amount: 1, size: 1.4)
        mix.finish(fadeIn: 0.5, fadeOut: 3)
        return mix
    }

    private static func house(_ def: SoundDef) -> SynthMix {
        let beat = 60.0 / 128, bars = 16
        let mix = SynthMix(seconds: def.seconds + 1)
        let prog = chords(57, [minor7, shift(major7, -4), shift(major, -7), shift(major, -2)])
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for b in [0.5, 1.5, 2.25, 3.5] {
                for n in c { mix.add(Synth.epiano(Synth.midi(n + 12), 0.2, release: 0.15), at: t + b * beat, gain: 0.16, pan: Float(n % 4) * 0.2 - 0.3) }
            }
            for i in 0..<8 { mix.add(Synth.tone(Synth.midi(c[0] - 24 + (i % 2) * 12), 0.18, wave: .square, attack: 0.003, decay: 0.1, sustain: 0.5, release: 0.04, cutoff: 450, cutoffEnv: 1), at: t + (Double(i) + 0.5) * beat / 2, gain: 0.3) }
        }
        drums(mix, beat: beat, bars: bars, kick: [0, 1, 2, 3], snare: [], hats: 0)
        let open = Synth.hat(open: true), clap = Synth.clap()
        for bar in 0..<bars {
            for b in 0..<4 {
                mix.add(open, at: (Double(bar * 4 + b) + 0.5) * beat, gain: 0.35, pan: 0.2)
                if b % 2 == 1 { mix.add(clap, at: Double(bar * 4 + b) * beat, gain: 0.45) }
            }
        }
        mix.reverb(amount: 0.3)
        mix.finish(fadeOut: 1.5)
        return mix
    }

    private static func ambient(_ def: SoundDef) -> SynthMix {
        let beat = 0.75, bars = 12
        let mix = SynthMix(seconds: def.seconds + 3)
        let prog = chords(64, [major7, shift(major7, 5), shift(minor7, -3), shift(major, 2)])
        var rng = Synth.Random(17)
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for n in c { mix.add(Synth.tone(Synth.midi(n - 12), 4 * beat, wave: .triangle, voices: 2, detune: 0.1, attack: 1.5, decay: 1, sustain: 0.9, release: 2, cutoff: 1500), at: t, gain: 0.08) }
            for i in 0..<6 {
                let n = c[Int(rng.unit() * Double(c.count)) % c.count] + 12 * (1 + Int(rng.unit() * 1.99))
                mix.add(Synth.bell(Synth.midi(n), 3, decay: 1.6), at: t + Double(i) * beat * 0.66 + rng.unit() * 0.05, gain: 0.12, pan: rng.next() * 0.7)
            }
        }
        mix.reverb(amount: 1, size: 1.5)
        mix.finish(fadeIn: 1, fadeOut: 4)
        return mix
    }

    private static func hiphop(_ def: SoundDef) -> SynthMix {
        let beat = 60.0 / 90, bars = 16
        let mix = SynthMix(seconds: def.seconds + 1)
        let prog = chords(53, [minor7, shift(minor7, -2), shift(major7, -4), shift(minor7, -5)])
        for bar in 0..<bars {
            let c = prog[bar % 4], t = Double(bar) * 4 * beat
            for n in c { mix.add(Synth.epiano(Synth.midi(n + 12), 1.8 * beat), at: t, gain: 0.2) }
            for n in c { mix.add(Synth.epiano(Synth.midi(n + 12), 1.2 * beat), at: t + 2.5 * beat, gain: 0.15) }
            mix.add(Synth.tone(Synth.midi(c[0] - 12), 1.5 * beat, wave: .sine, attack: 0.01, decay: 0.4, sustain: 0.7, release: 0.2), at: t, gain: 0.55)
            mix.add(Synth.tone(Synth.midi(c[0] - 12 + 3), 0.8 * beat, wave: .sine, attack: 0.01, decay: 0.4, sustain: 0.7, release: 0.2), at: t + 2.75 * beat, gain: 0.45)
        }
        drums(mix, beat: beat, bars: bars, kick: [0, 0.75, 2.5], snare: [1, 3], hats: 2, swing: 0.25)
        mix.reverb(amount: 0.35)
        mix.finish(fadeOut: 2)
        return mix
    }

    // MARK: Bruitages

    private static func effect(_ def: SoundDef) -> SynthMix {
        let mix = SynthMix(seconds: def.seconds)
        switch def.id {
        case "whoosh":
            mix.add(Synth.sweep(0.7, from: 300, to: 3500, seed: 3), at: 0, pan: -0.5)
            mix.add(Synth.sweep(0.7, from: 320, to: 3300, seed: 4), at: 0.01, pan: 0.5)
        case "swoosh-court":
            mix.add(Synth.sweep(0.35, from: 1800, to: 500, seed: 6, q: 0.6), at: 0)
        case "montee":
            mix.add(Synth.sweep(2.5, from: 150, to: 6000, rise: true, seed: 9), at: 0)
            mix.add(Synth.tone(110, 2.3, wave: .saw, voices: 3, attack: 2, decay: 0.1, sustain: 1, release: 0.15, cutoff: 300, cutoffEnv: 6, vibrato: 0.01), at: 0, gain: 0.3)
        case "impact":
            mix.add(Synth.kick(1.8, punch: 0.7), at: 0)
            mix.add(Synth.snare(0.6, seed: 2, tone: 80), at: 0, gain: 0.6)
            mix.reverb(amount: 0.8, size: 1.4)
        case "pop":
            var phase = 0.0
            var s = [Float](repeating: 0, count: Synth.frames(0.25))
            for i in s.indices {
                let t = Double(i) / Synth.sampleRate
                phase += (300 + 900 * exp(-t * 60)) / Synth.sampleRate
                s[i] = Float(sin(2 * .pi * phase) * exp(-t * 30))
            }
            mix.add(s, at: 0)
        case "clic":
            mix.add(Synth.hat(seed: 41), at: 0)
            mix.add(Synth.tone(2200, 0.01, attack: 0.0005, decay: 0.01, sustain: 0, release: 0.02), at: 0, gain: 0.5)
        case "ding":
            mix.add(Synth.bell(Synth.midi(88), 1.5, decay: 1.4), at: 0)
        case "notification":
            mix.add(Synth.bell(Synth.midi(79), 0.8, decay: 0.5), at: 0)
            mix.add(Synth.bell(Synth.midi(86), 0.6, decay: 0.5), at: 0.14)
        case "succes":
            for (i, n) in [72, 76, 79, 84].enumerated() { mix.add(Synth.bell(Synth.midi(n), 1.2, decay: 0.8), at: Double(i) * 0.09, gain: 0.8) }
        case "erreur":
            mix.add(Synth.tone(196, 0.18, wave: .square, attack: 0.005, decay: 0.1, sustain: 0.7, release: 0.05, cutoff: 1500), at: 0)
            mix.add(Synth.tone(147, 0.25, wave: .square, attack: 0.005, decay: 0.1, sustain: 0.7, release: 0.1, cutoff: 1500), at: 0.22)
        case "bip-censure":
            mix.add(Synth.tone(1000, 0.75, attack: 0.005, decay: 0.01, sustain: 1, release: 0.03), at: 0)
        case "caisse":
            mix.add(Synth.snare(0.2, seed: 8, tone: 600), at: 0, gain: 0.6)
            mix.add(Synth.bell(Synth.midi(91), 1.1, decay: 0.9), at: 0.12)
            mix.add(Synth.bell(Synth.midi(96), 1, decay: 0.7), at: 0.15, gain: 0.6)
        case "roulement":
            var t = 0.0, i = 0
            while t < 2.2 {
                mix.add(Synth.snare(0.12, seed: UInt64(i)), at: t, gain: Float(0.25 + 0.5 * t / 2.2), pan: i % 2 == 0 ? -0.2 : 0.2)
                t += 0.045; i += 1
            }
            mix.add(Synth.snare(0.4, seed: 99), at: 2.2)
            mix.add(Synth.hat(open: true, seed: 3), at: 2.2, gain: 1.4)
        case "ba-dum-tss":
            mix.add(Synth.snare(0.2, seed: 1, tone: 220), at: 0, gain: 0.8)
            mix.add(Synth.kick(0.5), at: 0.22)
            mix.add(Synth.hat(open: true, seed: 4), at: 0.45, gain: 1.6)
        case "applaudissements":
            var rng = Synth.Random(12)
            for i in 0..<420 {
                let t = rng.unit() * 3.4
                let env = Float(min(1, t / 0.4) * min(1, (3.8 - t) / 1.2))
                mix.add(Synth.clap(seed: UInt64(i)), at: t, gain: 0.18 * env, pan: rng.next() * 0.9)
            }
            mix.reverb(amount: 0.6)
        case "battement":
            for b in 0..<4 {
                mix.add(Synth.kick(0.3, punch: 0.2), at: Double(b) * 0.8, gain: 1)
                mix.add(Synth.kick(0.3, punch: 0.15), at: Double(b) * 0.8 + 0.22, gain: 0.7)
            }
        case "tic-tac":
            for i in 0..<8 {
                mix.add(Synth.tone(i % 2 == 0 ? 3200 : 2600, 0.004, attack: 0.0005, decay: 0.004, sustain: 0, release: 0.02), at: Double(i) * 0.5, gain: 0.8, pan: i % 2 == 0 ? -0.2 : 0.2)
                mix.add(Synth.hat(seed: UInt64(i)), at: Double(i) * 0.5, gain: 0.8)
            }
        case "machine-a-ecrire":
            var rng = Synth.Random(23)
            var t = 0.0, i = 0
            while t < 2.0 {
                mix.add(Synth.snare(0.05, seed: UInt64(i), tone: 900 + rng.unit() * 400), at: t, gain: 0.6 + 0.3 * Float(rng.unit()), pan: rng.next() * 0.3)
                t += 0.09 + rng.unit() * 0.08; i += 1
            }
            mix.add(Synth.bell(Synth.midi(93), 0.4, decay: 0.3), at: 2.0, gain: 0.7)
        case "glitch":
            var rng = Synth.Random(77)
            for i in 0..<10 {
                let f = 200 + rng.unit() * 2000
                mix.add(Synth.tone(f, 0.03, wave: .square, attack: 0.001, decay: 0.02, sustain: 0.8, release: 0.005), at: Double(i) * 0.05, gain: 0.5, pan: rng.next())
            }
            mix.add(Synth.sweep(0.6, from: 4000, to: 200, seed: 7), at: 0, gain: 0.5)
        case "magie":
            var rng = Synth.Random(5)
            for i in 0..<14 {
                let n = [84, 88, 91, 95, 96, 100][Int(rng.unit() * 5.99)]
                mix.add(Synth.bell(Synth.midi(n), 1.2, decay: 0.7), at: Double(i) * 0.06, gain: 0.35, pan: rng.next() * 0.8)
            }
            mix.add(Synth.sweep(1.5, from: 2000, to: 9000, seed: 2), at: 0, gain: 0.3)
            mix.reverb(amount: 0.7)
        default:
            break
        }
        mix.finish(peak: 0.85, fadeIn: 0.002, fadeOut: min(0.2, def.seconds / 4))
        return mix
    }
}
