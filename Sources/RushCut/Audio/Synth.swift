import Foundation

/// Petit synthétiseur utilisé pour fabriquer la bibliothèque de sons de RushCut.
/// Tout est calculé par le programme : aucun enregistrement extérieur, donc aucun droit d'auteur à payer.
let twoPi: Double = 2 * Double.pi

enum Synth {
    static let sampleRate = 44_100.0

    enum Wave { case sine, saw, square, triangle }

    /// Générateur pseudo-aléatoire déterministe (mêmes sons à chaque génération).
    struct Random {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 1) % 2_000_001) / 1_000_000 - 1
        }
        mutating func unit() -> Double { Double(next() + 1) / 2 }
    }

    static func midi(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
    static func frames(_ seconds: Double) -> Int { max(1, Int(seconds * sampleRate)) }

    private static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    /// Enveloppe ADSR (durées en secondes ; `hold` = durée de la note avant le relâchement).
    static func envelope(_ i: Int, hold: Double, attack: Double, decay: Double, sustain: Double, release: Double) -> Double {
        let t = Double(i) / sampleRate
        if t < attack { return t / max(attack, 1e-4) }
        if t < hold {
            let d = t - attack
            return d < decay ? 1 - (1 - sustain) * d / max(decay, 1e-4) : sustain
        }
        let level: Double
        if hold < attack {
            level = hold / max(attack, 1e-4)
        } else if hold - attack < decay {
            level = 1 - (1 - sustain) * (hold - attack) / max(decay, 1e-4)
        } else {
            level = sustain
        }
        let fall: Double = 1 - (t - hold) / max(release, 1e-4)
        return max(0, level * fall)
    }

    /// Note d'oscillateur(s), avec désaccord, vibrato et filtre passe-bas d'un pôle (qui s'ouvre puis se referme).
    static func tone(_ freq: Double, _ hold: Double, wave: Wave = .sine, voices: Int = 1, detune: Double = 0.08,
                     attack: Double = 0.01, decay: Double = 0.2, sustain: Double = 0.7, release: Double = 0.2,
                     cutoff: Double? = nil, cutoffEnv: Double = 0, vibrato: Double = 0) -> [Float] {
        let n = frames(hold + release)
        var out = [Float](repeating: 0, count: n)
        var phases = [Double](repeating: 0, count: voices)
        var lp = 0.0
        let ratios = (0..<voices).map { v -> Double in
            let spread = voices == 1 ? 0 : (Double(v) / Double(voices - 1) - 0.5) * 2 * detune
            return pow(2, spread / 12)
        }
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var vib: Double = 1
            if vibrato > 0 { vib += vibrato * sin(twoPi * 5.5 * t) * min(1, t * 2) }
            var s = 0.0
            for v in 0..<voices {
                let f = freq * vib * ratios[v]
                let dt = f / sampleRate
                var p = phases[v]
                switch wave {
                case .sine: s += sin(twoPi * p)
                case .saw: s += 2 * p - 1 - polyBLEP(p, dt)
                case .square:
                    var q = p < 0.5 ? 1.0 : -1.0
                    q += polyBLEP(p, dt)
                    q -= polyBLEP((p + 0.5).truncatingRemainder(dividingBy: 1), dt)
                    s += q
                case .triangle: s += 1 - 4 * abs(p - 0.5)
                }
                p += dt
                if p >= 1 { p -= 1 }
                phases[v] = p
            }
            s /= Double(voices)
            let env = envelope(i, hold: hold, attack: attack, decay: decay, sustain: sustain, release: release)
            if let cutoff {
                let c = min(18_000, cutoff * (1 + cutoffEnv * env))
                let a: Double = 1 - exp(-twoPi * c / sampleRate)
                lp += a * (s - lp)
                s = lp
            }
            out[i] = Float(s * env)
        }
        return out
    }

    /// Corde pincée (algorithme de Karplus-Strong) : guitare, harpe, pizzicato.
    static func pluck(_ freq: Double, _ seconds: Double, brightness: Double = 0.5, seed: UInt64 = 1) -> [Float] {
        let n = frames(seconds)
        let period = max(2, Int(sampleRate / freq))
        var rng = Random(seed &+ UInt64(freq * 100))
        var ring = (0..<period).map { _ in rng.next() }
        var out = [Float](repeating: 0, count: n)
        let damp = Float(0.996 + 0.0035 * (1 - brightness))
        let mixA = Float(0.5 + 0.45 * brightness)
        var idx = 0
        for i in 0..<n {
            let a = ring[idx], b = ring[(idx + 1) % period]
            let v = (mixA * a + (1 - mixA) * b) * min(damp, 0.9995)
            out[i] = a
            ring[idx] = v
            idx = (idx + 1) % period
        }
        let fade = min(n, frames(0.05))
        for i in 0..<fade { out[n - 1 - i] *= Float(i) / Float(fade) }
        return out
    }

    /// Cloche / glockenspiel : partiels inharmoniques qui décroissent.
    static func bell(_ freq: Double, _ seconds: Double, decay: Double = 1.2) -> [Float] {
        let partials: [(Double, Double, Double)] = [(1, 1, 1), (2.76, 0.5, 0.6), (5.4, 0.25, 0.4), (8.93, 0.12, 0.25)]
        let n = frames(seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var s = 0.0
            for (ratio, amp, d) in partials {
                let w: Double = twoPi * freq * ratio * t
                let e: Double = exp(-t / (decay * d))
                s += amp * sin(w) * e
            }
            let attack: Double = min(1, t * 400)
            out[i] = Float(s * attack * 0.6)
        }
        return out
    }

    /// Piano électrique : sinus avec harmoniques qui s'éteignent vite et léger trémolo.
    static func epiano(_ freq: Double, _ hold: Double, release: Double = 0.4) -> [Float] {
        let n = frames(hold + release)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = envelope(i, hold: hold, attack: 0.005, decay: 1.5, sustain: 0.35, release: release)
            let bright = exp(-t * 6)
            let w: Double = twoPi * freq * t
            var s: Double = sin(w)
            s += 0.35 * bright * sin(2 * w)
            s += 0.15 * bright * sin(4 * w)
            let tremolo: Double = 1 + 0.08 * sin(twoPi * 4.5 * t)
            out[i] = Float(s * env * tremolo * 0.6)
        }
        return out
    }

    /// Marimba : sinus avec 4ᵉ harmonique, décroissance rapide.
    static func marimba(_ freq: Double, _ seconds: Double = 0.6) -> [Float] {
        let n = frames(seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let w: Double = twoPi * freq * t
            let a: Double = sin(w) * exp(-t * 7)
            let b: Double = 0.3 * sin(3.9 * w) * exp(-t * 25)
            let attack: Double = min(1, t * 1000)
            out[i] = Float((a + b) * attack * 0.8)
        }
        return out
    }

    // MARK: Batterie

    static func kick(_ seconds: Double = 0.45, punch: Double = 1) -> [Float] {
        let n = frames(seconds)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = 45 + 110 * punch * exp(-t * 28)
            phase += f / sampleRate
            let body: Double = sin(twoPi * phase) * exp(-t * 7)
            let click: Double = t < 0.004 ? 0.4 : 0
            out[i] = Float(body + click)
        }
        return out
    }

    static func snare(_ seconds: Double = 0.25, seed: UInt64 = 7, tone: Double = 190) -> [Float] {
        var rng = Random(seed)
        let n = frames(seconds)
        var out = [Float](repeating: 0, count: n)
        var prev: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let white = rng.next()
            let hp = white - prev
            prev = white
            let noisePart: Double = Double(hp) * 0.55 * exp(-t * 16)
            let tonePart: Double = sin(twoPi * tone * t) * 0.5 * exp(-t * 30)
            out[i] = Float(noisePart + tonePart)
        }
        return out
    }

    static func hat(open: Bool = false, seed: UInt64 = 11) -> [Float] {
        var rng = Random(seed)
        let seconds = open ? 0.35 : 0.06
        let n = frames(seconds)
        var out = [Float](repeating: 0, count: n)
        var x1: Float = 0, x2: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let w = rng.next()
            let hp = w - 2 * x1 + x2
            x2 = x1; x1 = w
            out[i] = hp * 0.22 * Float(exp(-t * (open ? 9 : 60)))
        }
        return out
    }

    static func clap(seed: UInt64 = 21) -> [Float] {
        var rng = Random(seed)
        let n = frames(0.3)
        var out = [Float](repeating: 0, count: n)
        var bp: Float = 0, prev: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let burst: Double
            if t < 0.03 { burst = exp(-300 * t.truncatingRemainder(dividingBy: 0.01)) } else { burst = exp(-18 * (t - 0.03)) }
            let w = rng.next()
            let hp = w - prev
            prev = w
            bp += 0.35 * (hp - bp)
            out[i] = bp * Float(burst) * 1.4
        }
        return out
    }

    /// Bruit filtré qui balaie les fréquences (souffle, « whoosh », montée).
    static func sweep(_ seconds: Double, from f0: Double, to f1: Double, rise: Bool = false, seed: UInt64 = 5, q: Double = 0.4) -> [Float] {
        var rng = Random(seed)
        let n = frames(seconds)
        var out = [Float](repeating: 0, count: n)
        var low = 0.0, band = 0.0
        for i in 0..<n {
            let p = Double(i) / Double(n)
            let f = f0 * pow(f1 / f0, p)
            let fc: Double = 2 * sin(Double.pi * min(f, sampleRate / 6) / sampleRate)
            let x = Double(rng.next())
            low += fc * band
            let high = x - low - q * band
            band += fc * high
            let env: Double
            if rise { env = pow(p, 1.6) * (1 - pow(p, 40)) } else { let h: Double = sin(Double.pi * p); env = h * h }
            out[i] = Float(band * env * 0.9)
        }
        return out
    }
}

/// Table de mixage stéréo, avec réverbération simple.
final class SynthMix {
    let sampleRate = Synth.sampleRate
    var left: [Float]
    var right: [Float]

    init(seconds: Double) {
        let n = Synth.frames(seconds)
        left = [Float](repeating: 0, count: n)
        right = [Float](repeating: 0, count: n)
    }

    var count: Int { left.count }

    func add(_ s: [Float], at seconds: Double, gain: Float = 1, pan: Float = 0) {
        let start = Int(seconds * sampleRate)
        guard start < count else { return }
        let angle: Double = (Double(pan) + 1) * Double.pi / 4
        let gl = gain * Float(cos(angle)) * 1.414, gr = gain * Float(sin(angle)) * 1.414
        let end = min(count, start + s.count)
        var i = max(0, start)
        while i < end {
            let v = s[i - start]
            left[i] += v * gl
            right[i] += v * gr
            i += 1
        }
    }

    /// Réverbération de Schroeder (peignes en parallèle puis passe-tout).
    func reverb(amount: Float, size: Double = 1) {
        guard amount > 0 else { return }
        func process(_ input: [Float], offset: Int) -> [Float] {
            let combs = [1557, 1617, 1491, 1422].map { Int(Double($0 + offset) * size) }
            var out = [Float](repeating: 0, count: input.count)
            for d in combs {
                var buffer = [Float](repeating: 0, count: d)
                var idx = 0, filt: Float = 0
                for i in 0..<input.count {
                    let y = buffer[idx]
                    filt = y * 0.8 + filt * 0.2
                    buffer[idx] = input[i] * 0.25 + filt * 0.82
                    idx = (idx + 1) % d
                    out[i] += y
                }
            }
            for d in [556 + offset, 441 + offset] {
                var buffer = [Float](repeating: 0, count: d)
                var idx = 0
                for i in 0..<out.count {
                    let b = buffer[idx]
                    let y = -out[i] + b
                    buffer[idx] = out[i] + b * 0.5
                    idx = (idx + 1) % d
                    out[i] = y
                }
            }
            return out
        }
        let wl = process(left, offset: 0), wr = process(right, offset: 23)
        for i in 0..<count {
            left[i] += wl[i] * amount * 0.25
            right[i] += wr[i] * amount * 0.25
        }
    }

    /// Ramène le niveau crête à `peak` et adoucit les extrémités.
    func finish(peak: Float = 0.89, fadeIn: Double = 0.005, fadeOut: Double = 0.4) {
        var m: Float = 1e-6
        for i in 0..<count { m = max(m, abs(left[i]), abs(right[i])) }
        let g = peak / m
        let fi = Synth.frames(fadeIn), fo = Synth.frames(fadeOut)
        for i in 0..<count {
            var e: Float = 1
            if i < fi { e = Float(i) / Float(fi) }
            if i > count - fo { e = min(e, Float(count - i) / Float(fo)) }
            left[i] *= g * e
            right[i] *= g * e
        }
    }

    /// Échantillons entrelacés (gauche, droite…).
    var interleaved: [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        for i in 0..<count { out[2 * i] = left[i]; out[2 * i + 1] = right[i] }
        return out
    }
}
