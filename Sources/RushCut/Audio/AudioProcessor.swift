import Foundation
import AVFoundation
import CryptoKit

/// Nettoyage de la voix (passe-haut + expanseur) et gain au-delà de 0 dB, calculés à l'avance dans un fichier.
/// Le son traité remplace le son d'origine dans la composition : l'aperçu et l'export entendent exactement la même chose.
struct VoiceCleaner {
    let sampleRate: Float
    var hpX: [Float] = [0, 0]
    var hpY: [Float] = [0, 0]
    var envelope: [Float] = [0, 0]
    var gateGain: [Float] = [1, 1]

    init(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    /// Traite des échantillons entrelacés stéréo ; `gain` et `denoise` sont donnés par blocs.
    mutating func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, gain: (Int) -> Float, denoise: Float) {
        let rc: Float = 1 / (2 * Float.pi * 90)
        let dt: Float = 1 / sampleRate
        let hpA: Float = rc / (rc + dt)
        let attack: Float = exp(-1 / (0.005 * sampleRate))
        let release: Float = exp(-1 / (0.12 * sampleRate))
        let threshold: Float = 0.004 + 0.05 * denoise * denoise
        let exponent: Float = 1 + 2 * denoise
        for i in 0..<frames {
            let g = gain(i)
            for ch in 0..<2 {
                var x = samples[2 * i + ch]
                if denoise > 0 {
                    let y: Float = hpA * (hpY[ch] + x - hpX[ch])
                    hpX[ch] = x
                    hpY[ch] = y
                    x = y
                    let level = abs(x)
                    let k: Float = level > envelope[ch] ? attack : release
                    envelope[ch] = k * envelope[ch] + (1 - k) * level
                    var target: Float = 1
                    if envelope[ch] < threshold {
                        let ratio: Float = envelope[ch] / threshold
                        target = max(0.05, pow(ratio, exponent))
                    }
                    gateGain[ch] += (target - gateGain[ch]) * 0.002
                    x *= gateGain[ch]
                }
                x *= g
                if g > 1 {
                    let a = abs(x)
                    if a > 0.8 {
                        let soft: Float = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
                        x = x < 0 ? -soft : soft
                    }
                }
                samples[2 * i + ch] = x
            }
        }
    }
}

enum AudioPreprocessor {
    static let version = 1

    static var folder: URL { AppPaths.ensure(AppPaths.caches.appendingPathComponent("Sons traités", isDirectory: true)) }

    /// Vrai quand le son du clip doit être traité (gain au-delà de 0 dB ou réduction de bruit).
    static func needsProcessing(_ clip: Clip) -> Bool {
        if clip.audio.isMuted { return false }
        return clip.audio.denoise > 0 || clip.audio.volumeDB > 0 || clip.keyframes(.volume).contains { $0.value > 0 }
            || clip.audio.voiceEffect != nil
    }

    /// Nom de fichier stable qui dépend de tout ce qui change le résultat.
    static func key(_ clip: Clip, sourcePath: String) -> String {
        var parts = ["v\(version)", sourcePath, "\(clip.sourceIn.ticks)", "\(clip.sourceLength.ticks)",
                     String(format: "%.4f", clip.speed.rate), String(format: "%.2f", clip.audio.volumeDB), String(format: "%.3f", clip.audio.denoise), clip.audio.voiceEffect ?? "-"]
        if let date = (try? FileManager.default.attributesOfItem(atPath: sourcePath))?[.modificationDate] as? Date {
            parts.append("\(date.timeIntervalSince1970)")
        }
        for k in clip.keyframes(.volume) { parts.append("\(k.time.ticks):\(k.value):\(k.interpolation.rawValue)") }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func cacheURL(_ clip: Clip, sourceURL: URL) -> URL {
        folder.appendingPathComponent("\(key(clip, sourcePath: sourceURL.path)).caf")
    }

    /// Fichier traité prêt à l'emploi, s'il existe.
    static func processedURL(_ clip: Clip, sourceURL: URL) -> URL? {
        guard needsProcessing(clip) else { return nil }
        let url = cacheURL(clip, sourceURL: sourceURL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Clips dont le son traité manque encore.
    static func missing(_ project: Project, resolve: (MediaRef) -> URL? = MediaResolver.url(for:)) -> [(Clip, URL)] {
        var jobs: [(Clip, URL)] = []
        var seen = Set<String>()
        for track in project.tracks where !track.isMuted {
            for clip in track.clips where needsProcessing(clip) {
                guard let media = project.media(clip.mediaID), media.hasAudio || media.kind == .audio, let url = resolve(media) else { continue }
                let target = cacheURL(clip, sourceURL: url)
                if FileManager.default.fileExists(atPath: target.path) || seen.contains(target.path) { continue }
                seen.insert(target.path)
                jobs.append((clip, url))
            }
        }
        return jobs
    }

    /// Empreinte des sons traités disponibles (change quand un fichier traité apparaît).
    static func signature(_ project: Project) -> Int {
        var h = Hasher()
        for track in project.tracks {
            for clip in track.clips where needsProcessing(clip) {
                guard let media = project.media(clip.mediaID), let url = MediaResolver.url(for: media) else { continue }
                h.combine(processedURL(clip, sourceURL: url)?.path)
            }
        }
        return h.finalize()
    }

    /// Crée tous les fichiers traités manquants.
    static func prepare(_ project: Project, resolve: @escaping (MediaRef) -> URL? = MediaResolver.url(for:)) async {
        for (clip, url) in missing(project, resolve: resolve) {
            if Task.isCancelled { return }
            do { try await render(clip, source: url) } catch { Log.error("Traitement du son (\(clip.name)) : \(error.localizedDescription)") }
        }
    }

    /// Lit la partie utilisée du son, la traite et l'écrit dans le cache.
    static func render(_ clip: Clip, source: URL) async throws {
        let target = cacheURL(clip, sourceURL: source)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let assetDuration = RTime(try await asset.load(.duration))
        let length = min(clip.sourceLength, assetDuration - clip.sourceIn)
        guard length > .zero else { return }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: clip.sourceIn.cmTime, duration: length.cmTime)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RushError.render("lecture du son impossible") }

        let temp = folder.appendingPathComponent(".\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: temp, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var cleaner = VoiceCleaner(sampleRate: 48_000)
        var fx = clip.audio.voiceEffect.map { VoiceFX(id: $0) }
        let rate = max(0.01, clip.speed.rate)
        let denoise = Float(clip.audio.denoise)
        var framesDone = 0
        let start = clip.sourceIn.seconds
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let frames = bytes / 8
            guard frames > 0 else { continue }
            var samples = [Float](repeating: 0, count: frames * 2)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let base = pts.isFinite ? pts - start : Double(framesDone) / 48_000
            // Gain par blocs de 256 images, selon le volume (images clés comprises) à cet instant du clip.
            let blocks = (frames + 255) / 256
            var gains = [Float](repeating: 1, count: blocks)
            for b in 0..<blocks {
                let local = (base + Double(b * 256 + 128) / 48_000) / rate
                gains[b] = AudioSettings.extraGain(db: clip.value(.volume, at: RTime(seconds: local)))
            }
            samples.withUnsafeMutableBufferPointer { p in
                cleaner.process(p.baseAddress!, frames: frames, gain: { gains[min($0 / 256, blocks - 1)] }, denoise: denoise)
                fx?.process(p.baseAddress!, frames: frames)
            }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let channels = pcm.floatChannelData else { continue }
            pcm.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                channels[0][i] = samples[2 * i]
                channels[1][i] = samples[2 * i + 1]
            }
            try file.write(from: pcm)
            framesDone += frames
        }
        file.close()
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: temp)
            throw reader.error ?? RushError.render("lecture du son interrompue")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
    }
}

// MARK: - Effets de voix (lot V2)

struct VoiceEffectDef: Identifiable, Hashable {
    let id: String
    let name: String
}

enum VoiceEffects {
    static let all: [VoiceEffectDef] = [
        ("robot", "Robot"), ("helium", "Hélium (aigu)"), ("monstre", "Monstre (grave)"), ("echo", "Écho"),
        ("radio", "Radio"), ("telephone", "Téléphone"), ("megaphone", "Mégaphone"), ("grotte", "Grotte"), ("chorale", "Voix doublée"),
    ].map { VoiceEffectDef(id: $0.0, name: $0.1) }
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

/// Traitement d'un effet de voix, échantillon par échantillon (stéréo entrelacée, 48 kHz).
struct VoiceFX {
    let id: String
    let sr: Float = 48_000
    private var t: Float = 0
    // Filtres d'un pôle par canal.
    private var hpX: [Float] = [0, 0], hpY: [Float] = [0, 0], lp: [Float] = [0, 0]
    // Ligne à retard (écho, robot, chorale, hauteur).
    private var delay: [[Float]]
    private var w = 0
    private var phase: Float = 0
    // Réverbération (grotte).
    private var combs: [[[Float]]] = []
    private var combIdx: [[Int]] = []
    private var combFilt: [[Float]] = []

    init(id: String) {
        self.id = id
        delay = [[Float](repeating: 0, count: 48_000), [Float](repeating: 0, count: 48_000)]
        if id == "grotte" {
            let sizes = [1557, 1617, 1491, 1422].map { $0 * 2 }
            combs = (0..<2).map { ch in sizes.map { [Float](repeating: 0, count: $0 + ch * 23) } }
            combIdx = [[0, 0, 0, 0], [0, 0, 0, 0]]
            combFilt = [[0, 0, 0, 0], [0, 0, 0, 0]]
        }
    }

    private mutating func highpass(_ x: Float, _ ch: Int, _ f: Float) -> Float {
        let rc: Float = 1 / (2 * Float.pi * f), dt: Float = 1 / sr
        let a: Float = rc / (rc + dt)
        let y: Float = a * (hpY[ch] + x - hpX[ch])
        hpX[ch] = x
        hpY[ch] = y
        return y
    }

    private mutating func lowpass(_ x: Float, _ ch: Int, _ f: Float) -> Float {
        let a: Float = 1 - exp(-2 * Float.pi * f / sr)
        lp[ch] += a * (x - lp[ch])
        return lp[ch]
    }

    private func read(_ ch: Int, _ d: Float) -> Float {
        let n = delay[ch].count
        let pos = Float(w) - d
        let i0 = Int(floor(pos))
        let frac = pos - Float(i0)
        let a = delay[ch][((i0 % n) + n) % n], b = delay[ch][(((i0 + 1) % n) + n) % n]
        return a + (b - a) * frac
    }

    private func pitch(_ ch: Int, ratio: Float) -> Float {
        let size: Float = 2400
        let p1 = phase, p2 = (phase + 0.5).truncatingRemainder(dividingBy: 1)
        let w1: Float = 1 - abs(2 * p1 - 1), w2: Float = 1 - abs(2 * p2 - 1)
        _ = ratio
        return read(ch, p1 * size + 2) * w1 + read(ch, p2 * size + 2) * w2
    }

    mutating func process(_ s: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            for ch in 0..<2 { delay[ch][w] = s[2 * i + ch] }
            for ch in 0..<2 {
                let x = s[2 * i + ch]
                var y = x
                switch id {
                case "robot":
                    let ring: Float = sin(2 * Float.pi * 55 * t)
                    y = (x * 0.6 + read(ch, 0.009 * sr) * 0.5) * ring * 1.6
                case "helium", "monstre":
                    y = pitch(ch, ratio: id == "helium" ? 1.5 : 0.7)
                case "echo":
                    let e = read(ch, 0.32 * sr)
                    y = x + 0.45 * e
                    delay[ch][w] = x + 0.4 * e
                case "radio":
                    let band = lowpass(highpass(x, ch, 300), ch, 3000)
                    y = tanh(band * 2.5) * 0.7
                case "telephone":
                    let band = lowpass(highpass(x, ch, 450), ch, 3200)
                    y = (band * 24).rounded() / 24 * 1.2
                case "megaphone":
                    let band = lowpass(highpass(x, ch, 650), ch, 2600)
                    y = max(-0.6, min(0.6, band * 4)) * 1.1
                case "grotte":
                    var wet: Float = 0
                    for k in 0..<combs[ch].count {
                        let n = combs[ch][k].count
                        let v = combs[ch][k][combIdx[ch][k]]
                        combFilt[ch][k] = v * 0.7 + combFilt[ch][k] * 0.3
                        combs[ch][k][combIdx[ch][k]] = x * 0.25 + combFilt[ch][k] * 0.86
                        combIdx[ch][k] = (combIdx[ch][k] + 1) % n
                        wet += v
                    }
                    y = x * 0.7 + wet * 0.35
                case "chorale":
                    let mod: Float = 0.012 * sr + 0.003 * sr * sin(2 * Float.pi * 0.8 * t + Float(ch))
                    y = x * 0.7 + read(ch, mod) * 0.6
                default:
                    break
                }
                s[2 * i + ch] = max(-1, min(1, y))
            }
            // Têtes de lecture du changement de hauteur.
            if id == "helium" || id == "monstre" {
                let ratio: Float = id == "helium" ? 1.5 : 0.7
                phase += (1 - ratio) / 2400
                if phase < 0 { phase += 1 }
                if phase >= 1 { phase -= 1 }
            }
            w = (w + 1) % delay[0].count
            t += 1 / sr
            if t > 1000 { t -= 1000 }
        }
    }
}
