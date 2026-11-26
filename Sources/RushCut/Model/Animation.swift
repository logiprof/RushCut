import Foundation

/// Paramètres animables par images clés.
enum KeyProp: String, CaseIterable, Sendable {
    case positionX, positionY, scale, rotation, opacity, volume

    var label: String {
        switch self {
        case .positionX: return "Position X"
        case .positionY: return "Position Y"
        case .scale: return "Échelle"
        case .rotation: return "Rotation"
        case .opacity: return "Opacité"
        case .volume: return "Volume"
        }
    }
}

enum Easing {
    static func apply(_ t: Double, _ mode: Interpolation) -> Double {
        let x = min(max(t, 0), 1)
        switch mode {
        case .lineaire: return x
        case .douce: return x * x * (3 - 2 * x)
        case .entree: return x * x
        case .sortie: return 1 - (1 - x) * (1 - x)
        case .maintien: return 0
        }
    }
}

extension Clip {
    /// Valeur de base (sans image clé) d'un paramètre.
    func baseValue(_ prop: KeyProp) -> Double {
        switch prop {
        case .positionX: return transform.positionX
        case .positionY: return transform.positionY
        case .scale: return transform.scale
        case .rotation: return transform.rotation
        case .opacity: return opacity
        case .volume: return audio.volumeDB
        }
    }

    mutating func setBaseValue(_ prop: KeyProp, _ value: Double) {
        switch prop {
        case .positionX: transform.positionX = value
        case .positionY: transform.positionY = value
        case .scale: transform.scale = value
        case .rotation: transform.rotation = value
        case .opacity: opacity = value
        case .volume: audio.volumeDB = value
        }
    }

    func keyframes(_ prop: KeyProp) -> [Keyframe] {
        (keyframes[prop.rawValue] ?? []).sorted { $0.time < $1.time }
    }

    func hasKeyframes(_ prop: KeyProp) -> Bool { !(keyframes[prop.rawValue] ?? []).isEmpty }

    /// Valeur d'un paramètre à un instant du clip (images clés interpolées).
    func value(_ prop: KeyProp, at local: RTime) -> Double {
        let keys = keyframes(prop)
        guard let first = keys.first else { return baseValue(prop) }
        if local <= first.time { return first.value }
        guard let last = keys.last, local < last.time else { return keys.last!.value }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if local >= a.time && local < b.time {
                let span = max(1, (b.time - a.time).ticks)
                let t = Double((local - a.time).ticks) / Double(span)
                return a.value + (b.value - a.value) * Easing.apply(t, a.interpolation)
            }
        }
        return last.value
    }

    /// Instant d'image clé à moins d'une image de `local`.
    func keyframeIndex(_ prop: KeyProp, near local: RTime, fps: Int) -> Int? {
        let tolerance = RTime.frame(fps: fps).ticks / 2
        return (keyframes[prop.rawValue] ?? []).firstIndex { abs(($0.time - local).ticks) <= tolerance }
    }

    /// Règle un paramètre : s'il a des images clés, crée ou modifie celle de l'instant ; sinon change la valeur de base.
    mutating func set(_ prop: KeyProp, _ value: Double, at local: RTime?, fps: Int) {
        guard let local, hasKeyframes(prop) else {
            setBaseValue(prop, value)
            return
        }
        var keys = keyframes[prop.rawValue] ?? []
        if let i = keys.firstIndex(where: { abs(($0.time - local).ticks) <= RTime.frame(fps: fps).ticks / 2 }) {
            keys[i].value = value
        } else {
            keys.append(Keyframe(time: local.snapped(fps: fps), value: value))
            keys.sort { $0.time < $1.time }
        }
        keyframes[prop.rawValue] = keys
    }

    /// Ajoute ou retire l'image clé d'un paramètre à l'instant donné.
    mutating func toggleKeyframe(_ prop: KeyProp, at local: RTime, fps: Int) {
        var keys = keyframes[prop.rawValue] ?? []
        if let i = keyframeIndex(prop, near: local, fps: fps) {
            keys.remove(at: i)
        } else {
            keys.append(Keyframe(time: local.snapped(fps: fps), value: value(prop, at: local)))
            keys.sort { $0.time < $1.time }
        }
        keyframes[prop.rawValue] = keys.isEmpty ? nil : keys
    }

    /// Décale ou rogne les images clés après un rognage du début ou une coupe.
    mutating func shiftKeyframes(by delta: RTime) {
        guard delta != .zero else { return }
        for (key, list) in keyframes {
            keyframes[key] = list.map { var k = $0; k.time = k.time - delta; return k }
        }
    }

    var hasAnyKeyframe: Bool { keyframes.values.contains { !$0.isEmpty } }

    /// Longueur de source consommée (vitesse constante).
    var sourceLength: RTime { duration * max(0.01, speed.rate) }
}
