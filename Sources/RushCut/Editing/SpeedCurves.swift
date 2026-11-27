import Foundation

/// Courbes de vitesse (lot V2). La courbe répartit le temps à l'intérieur du clip ;
/// `speed.rate` garde la vitesse moyenne, si bien que la longueur de source consommée ne change pas.
struct SpeedPreset: Identifiable {
    let id: String
    let name: String
    let points: [SpeedPoint]
}

enum SpeedCurves {
    static let presets: [SpeedPreset] = [
        SpeedPreset(id: "montage", name: "Montage", points: pts([(0, 1), (0.3, 1), (0.4, 0.3), (0.6, 0.3), (0.7, 2), (1, 2)])),
        SpeedPreset(id: "heros", name: "Héros", points: pts([(0, 2), (0.4, 2), (0.5, 0.25), (0.6, 2), (1, 2)])),
        SpeedPreset(id: "balle", name: "Balle", points: pts([(0, 1), (0.35, 1), (0.45, 0.2), (0.55, 0.2), (0.65, 1), (1, 1)])),
        SpeedPreset(id: "saut", name: "Saut", points: pts([(0, 1), (0.42, 1), (0.5, 5), (0.58, 1), (1, 1)])),
        SpeedPreset(id: "flash-entrant", name: "Flash entrant", points: pts([(0, 5), (0.3, 5), (0.4, 1), (1, 1)])),
        SpeedPreset(id: "flash-sortant", name: "Flash sortant", points: pts([(0, 1), (0.6, 1), (0.7, 5), (1, 5)])),
        SpeedPreset(id: "acceleration", name: "Accélération", points: pts([(0, 0.5), (1, 3)])),
        SpeedPreset(id: "ralenti-final", name: "Ralenti final", points: pts([(0, 1.5), (0.7, 1), (1, 0.3)])),
    ]

    private static func pts(_ list: [(Double, Double)]) -> [SpeedPoint] { list.map { SpeedPoint(position: $0.0, rate: $0.1) } }

    /// Vitesse à une position de la source (0–1), interpolation linéaire.
    static func rate(_ points: [SpeedPoint], at p: Double) -> Double {
        let sorted = points.sorted { $0.position < $1.position }
        guard let first = sorted.first, let last = sorted.last else { return 1 }
        if p <= first.position { return first.rate }
        if p >= last.position { return last.rate }
        for i in 0..<(sorted.count - 1) where p >= sorted[i].position && p <= sorted[i + 1].position {
            let a = sorted[i], b = sorted[i + 1]
            let t = (p - a.position) / max(1e-6, b.position - a.position)
            return a.rate + (b.rate - a.rate) * t
        }
        return 1
    }

    static let segments = 24

    /// Durées relatives (somme = 1) des segments de source réguliers.
    static func segmentWeights(_ points: [SpeedPoint]) -> [Double] {
        let n = segments
        let raw = (0..<n).map { i -> Double in
            let mid = (Double(i) + 0.5) / Double(n)
            return 1 / max(0.05, rate(points, at: mid))
        }
        let total = raw.reduce(0, +)
        return raw.map { $0 / total }
    }

    /// Durée dans la timeline d'une source de longueur `sourceLength` jouée avec la courbe.
    static func duration(sourceLength: RTime, points: [SpeedPoint]) -> RTime {
        let n = Double(segments)
        let total = (0..<segments).map { i in 1 / max(0.05, rate(points, at: (Double(i) + 0.5) / n)) }.reduce(0, +) / n
        return RTime(seconds: sourceLength.seconds * total)
    }
}

extension Project {
    /// Applique une courbe de vitesse (vide = revenir à la vitesse constante de même durée moyenne).
    mutating func setSpeedCurve(_ id: UUID, points: [SpeedPoint], name: String?) {
        guard let loc = location(of: id), !tracks[loc.track].isLocked else { return }
        var c = tracks[loc.track].clips[loc.clip]
        let source = c.sourceLength
        let oldDuration = c.duration
        if points.isEmpty {
            c.speed.curve = []
            c.speed.curveName = nil
        } else {
            let d = SpeedCurves.duration(sourceLength: source, points: points).snapped(fps: settings.frameRate)
            c.duration = max(RTime.frame(fps: settings.frameRate), d)
            c.speed.rate = source.seconds / max(0.001, c.duration.seconds)
            c.speed.curve = points
            c.speed.curveName = name
        }
        // Les images clés suivent la nouvelle durée.
        if oldDuration != c.duration, oldDuration > .zero {
            let k = c.duration.seconds / oldDuration.seconds
            for (key, list) in c.keyframes { c.keyframes[key] = list.map { var f = $0; f.time = RTime(seconds: f.time.seconds * k); return f } }
        }
        clampFades(&c)
        tracks[loc.track].clips[loc.clip] = c
    }
}
