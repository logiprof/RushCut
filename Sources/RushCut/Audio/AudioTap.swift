import Foundation
import AVFoundation
import MediaToolbox
import os

/// Niveaux de sortie pendant la lecture (vu-mètre), alimentés par le traitement audio.
final class AudioMeter: @unchecked Sendable {
    static let shared = AudioMeter()
    private var lock = os_unfair_lock()
    private var peak: (Float, Float) = (0, 0)
    private var updated = Date.distantPast

    func report(left: Float, right: Float) {
        os_unfair_lock_lock(&lock)
        peak = (max(peak.0 * 0.9, left), max(peak.1 * 0.9, right))
        updated = Date()
        os_unfair_lock_unlock(&lock)
    }

    /// Niveaux crête récents (0–1+), qui retombent quand plus rien ne joue.
    func levels() -> (Float, Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let age = Date().timeIntervalSince(updated)
        if age > 0.25 { return (0, 0) }
        let fall = Float(max(0, 1 - age * 3))
        return (peak.0 * fall, peak.1 * fall)
    }

    /// Réinitialise le maximum (appelé après chaque lecture du vu-mètre).
    func decay() {
        os_unfair_lock_lock(&lock)
        peak = (peak.0 * 0.85, peak.1 * 0.85)
        os_unfair_lock_unlock(&lock)
    }
}

/// Relevé des premiers appels du traitement audio (pour les tests).
enum TapDiagnostics {
    nonisolated(unsafe) static var calls: [(start: Double, frames: Int, sampleRate: Double)] = []
    private static let lock = NSLock()

    static func record(start: Double, frames: Int, sampleRate: Double) {
        lock.lock()
        if calls.count < 400 { calls.append((start, frames, sampleRate)) }
        lock.unlock()
    }

    nonisolated(unsafe) static var errors: [OSStatus] = []

    static func recordError(_ status: OSStatus) {
        lock.lock()
        if errors.count < 50 { errors.append(status) }
        lock.unlock()
    }

    static func reset() {
        lock.lock(); calls = []; errors = []; lock.unlock()
    }

    static var summary: String {
        lock.lock(); defer { lock.unlock() }
        let list = calls.map { String(format: "%.3f+%d", $0.start, $0.frames) }
        return "\(calls.count) appels, premiers : \(list.prefix(4).joined(separator: " ")), derniers : \(list.suffix(6).joined(separator: " ")) ; erreurs : \(errors.prefix(5))"
    }
}

/// Réglages d'un morceau lus par le fil audio (copie figée, sans accès au projet).
struct TapSegment: Sendable {
    let start: Double
    let end: Double
    let clip: Clip

    func extraGain(at t: Double) -> Float {
        let db = clip.value(.volume, at: RTime(seconds: t - start))
        return AudioSettings.extraGain(db: db)
    }
}

/// État du traitement d'une piste : gain au-delà de 0 dB, réduction de bruit, limiteur, vu-mètre.
final class TapContext: @unchecked Sendable {
    let segments: [TapSegment]
    let needsProcessing: Bool
    var sampleRate: Double = 48_000
    var channels = 2
    var isFloat = true
    var nonInterleaved = true
    // Réduction de bruit : passe-haut d'un pôle + expanseur, par canal.
    var hpX: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]
    var hpY: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]
    var envelope: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]
    var gateGain: [Float] = [1, 1, 1, 1, 1, 1, 1, 1]
    var lastEnd: Double = -1

    init(segments: [AudioSegment]) {
        self.segments = segments.map { TapSegment(start: $0.start.seconds, end: $0.end.seconds, clip: $0.clip) }
        needsProcessing = segments.contains { s in
            s.clip.audio.denoise > 0 || s.clip.audio.volumeDB > 0
                || s.clip.keyframes(.volume).contains { $0.value > 0 } || s.clip.audio.voiceEffect != nil
        }
    }

    func segment(at t: Double) -> TapSegment? {
        segments.first { t >= $0.start && t < $0.end }
    }

    func process(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, start: Double) {
        guard isFloat, frames > 0 else { return }
        if abs(start - lastEnd) > 0.05 { resetState() }
        lastEnd = start + Double(frames) / sampleRate
        TapDiagnostics.record(start: start, frames: frames, sampleRate: sampleRate)
        // Gain et réduction de bruit calculés par blocs de 256 images (les paquets peuvent être longs).
        let block = 256
        let blocks = (frames + block - 1) / block
        var gains = [Float](repeating: 1, count: blocks)
        var denoises = [Float](repeating: 0, count: blocks)
        if needsProcessing {
            for b in 0..<blocks {
                let t = start + (Double(b * block) + Double(block) / 2) / sampleRate
                if let seg = segment(at: t) {
                    gains[b] = seg.extraGain(at: t)
                    denoises[b] = Float(seg.clip.audio.denoise)
                }
            }
        }
        let denoise = denoises.max() ?? 0
        var peaks: [Float] = [0, 0]

        func run(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int, channel: Int) {
            let ch = min(channel, 7)
            // Coefficients : passe-haut ~90 Hz, attaque 5 ms, relâchement 120 ms.
            let sr = Float(sampleRate)
            let rc: Float = 1 / (2 * Float.pi * 90)
            let dt: Float = 1 / sr
            let hpA: Float = rc / (rc + dt)
            let attack: Float = exp(-1 / (0.005 * sr))
            let release: Float = exp(-1 / (0.12 * sr))
            let threshold: Float = 0.004 + 0.05 * denoise * denoise
            var peak: Float = 0
            var i = 0
            while i < count {
                var x = samples[i * stride]
                let gain = gains[min(i / block, blocks - 1)]
                if denoises[min(i / block, blocks - 1)] > 0 {
                    let y = hpA * (hpY[ch] + x - hpX[ch])
                    hpX[ch] = x; hpY[ch] = y
                    x = y
                    let level = abs(x)
                    let k: Float = level > envelope[ch] ? attack : release
                    envelope[ch] = k * envelope[ch] + (1 - k) * level
                    var target: Float = 1
                    if envelope[ch] < threshold {
                        let ratio: Float = envelope[ch] / threshold
                        let exponent: Float = 1 + 2 * denoise
                        target = max(0.05, pow(ratio, exponent))
                    }
                    gateGain[ch] += (target - gateGain[ch]) * 0.002
                    x *= gateGain[ch]
                }
                x *= gain
                // Limiteur doux : évite la saturation quand le gain dépasse 0 dB.
                if gain > 1 {
                    let a = abs(x)
                    if a > 0.8 {
                        let soft: Float = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
                        x = x < 0 ? -soft : soft
                    }
                }
                samples[i * stride] = x
                peak = max(peak, abs(x))
                i += 1
            }
            if channel < 2 { peaks[channel] = max(peaks[channel], peak) }
        }

        if nonInterleaved {
            for (c, buffer) in list.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                run(data, count: count, stride: 1, channel: c)
            }
        } else if let buffer = list.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
            let n = max(1, Int(buffer.mNumberChannels))
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n))
            for c in 0..<n { run(data + c, count: count, stride: n, channel: c) }
        }
        AudioMeter.shared.report(left: peaks[0], right: list.count > 1 || !nonInterleaved ? peaks[1] : peaks[0])
    }

    private func resetState() {
        for i in 0..<8 { hpX[i] = 0; hpY[i] = 0; envelope[i] = 0; gateGain[i] = 1 }
    }
}

/// Traitement audio en temps réel branché sur la composition (aperçu et export).
enum AudioTap {
    /// Désactivable pour les tests de diagnostic.
    nonisolated(unsafe) static var enabled = true

    static func attach(to params: AVMutableAudioMixInputParameters, segments: [AudioSegment]) {
        guard enabled else { return }
        let context = TapContext(segments: segments)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                ctx.sampleRate = f.mSampleRate > 0 ? f.mSampleRate : 48_000
                ctx.channels = Int(f.mChannelsPerFrame)
                ctx.isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
                ctx.nonInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                var range = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, &range, numberFramesOut)
                guard status == noErr else {
                    // Pas de son source (zone vide de la piste) : on rend du silence plutôt que d'interrompre la piste.
                    TapDiagnostics.recordError(status)
                    for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    numberFramesOut.pointee = numberFrames
                    return
                }
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let start = range.start.isNumeric ? range.start.seconds : ctx.lastEnd
                ctx.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(numberFramesOut.pointee), start: start)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if status == noErr, let tap {
            params.audioTapProcessor = tap
        } else {
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            Log.info("Traitement audio indisponible (\(status))")
        }
    }
}
