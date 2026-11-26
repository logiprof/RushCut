import Foundation

/// Modification temporaire d'un calque (ajoutée à sa position, son échelle…).
struct AnimState: Equatable {
    /// Décalage en fraction du cadre.
    var dx = 0.0
    var dy = 0.0
    var scale = 1.0
    /// Degrés, sens horaire.
    var rotation = 0.0
    var opacity = 1.0
    /// Flou, en fraction de la hauteur du cadre.
    var blur = 0.0

    static let identity = AnimState()

    func combined(with o: AnimState) -> AnimState {
        AnimState(dx: dx + o.dx, dy: dy + o.dy, scale: scale * o.scale, rotation: rotation + o.rotation,
                  opacity: opacity * o.opacity, blur: blur + o.blur)
    }
}

enum AnimationKind: String, CaseIterable {
    case entree, sortie, boucle

    var label: String {
        switch self {
        case .entree: return "Entrée"
        case .sortie: return "Sortie"
        case .boucle: return "En boucle"
        }
    }
}

struct AnimationDef: Identifiable {
    let id: String
    let name: String
    let kind: AnimationKind
    /// Pour une entrée : p de 0 (début) à 1 (état normal). Pour une sortie : p de 0 (normal) à 1 (fin).
    /// Pour une boucle : p = phase de 0 à 1.
    let state: (Double) -> AnimState
}

enum Ease {
    static func outCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func inCubic(_ t: Double) -> Double { t * t * t }
    static func outBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
    static func outElastic(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
    }
    static func outBounce(_ t: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        var x = t
        if x < 1 / d1 { return n1 * x * x }
        if x < 2 / d1 { x -= 1.5 / d1; return n1 * x * x + 0.75 }
        if x < 2.5 / d1 { x -= 2.25 / d1; return n1 * x * x + 0.9375 }
        x -= 2.625 / d1
        return n1 * x * x + 0.984375
    }
}

/// Animations d'entrée, de sortie et en boucle (41 au total).
enum AnimationCatalog {
    static let all: [AnimationDef] = build()
    static let byID: [String: AnimationDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func list(_ kind: AnimationKind) -> [AnimationDef] { all.filter { $0.kind == kind } }

    /// État d'animation d'un clip à un instant (entrée, sortie et boucle combinées).
    static func state(for clip: Clip, local: RTime) -> AnimState {
        var result = AnimState.identity
        let t = local.seconds
        let total = clip.duration.seconds
        if let a = clip.animIn, let def = byID[a.id] {
            let d = max(0.05, min(a.duration.seconds, total))
            if t < d { result = result.combined(with: def.state(min(1, max(0, t / d)))) }
        }
        if let a = clip.animOut, let def = byID[a.id] {
            let d = max(0.05, min(a.duration.seconds, total))
            let startOut = total - d
            if t > startOut { result = result.combined(with: def.state(min(1, max(0, (t - startOut) / d)))) }
        }
        if let a = clip.animLoop, let def = byID[a.id] {
            let period = max(0.1, a.duration.seconds)
            result = result.combined(with: def.state((t / period).truncatingRemainder(dividingBy: 1)))
        }
        return result
    }

    private static func build() -> [AnimationDef] {
        var list: [AnimationDef] = []
        func entree(_ id: String, _ name: String, _ f: @escaping (Double) -> AnimState) {
            list.append(AnimationDef(id: "in-" + id, name: name, kind: .entree, state: f))
        }
        func sortie(_ id: String, _ name: String, _ f: @escaping (Double) -> AnimState) {
            list.append(AnimationDef(id: "out-" + id, name: name, kind: .sortie, state: f))
        }
        func boucle(_ id: String, _ name: String, _ f: @escaping (Double) -> AnimState) {
            list.append(AnimationDef(id: "loop-" + id, name: name, kind: .boucle, state: f))
        }
        // Entrées : p = 0 au début, 1 à l'état normal.
        entree("fondu", "Fondu") { p in AnimState(opacity: p) }
        entree("zoom-avant", "Zoom avant") { p in let e = Ease.outCubic(p); return AnimState(scale: 0.6 + 0.4 * e, opacity: p) }
        entree("zoom-arriere", "Zoom arrière") { p in let e = Ease.outCubic(p); return AnimState(scale: 1.4 - 0.4 * e, opacity: p) }
        entree("glisser-gauche", "Glisser depuis la gauche") { p in AnimState(dx: -0.6 * (1 - Ease.outCubic(p))) }
        entree("glisser-droite", "Glisser depuis la droite") { p in AnimState(dx: 0.6 * (1 - Ease.outCubic(p))) }
        entree("glisser-haut", "Glisser depuis le haut") { p in AnimState(dy: -0.6 * (1 - Ease.outCubic(p))) }
        entree("glisser-bas", "Glisser depuis le bas") { p in AnimState(dy: 0.6 * (1 - Ease.outCubic(p))) }
        entree("rebond", "Rebond") { p in AnimState(scale: max(0.01, Ease.outBack(p)), opacity: min(1, p * 3)) }
        entree("rotation", "Rotation") { p in AnimState(rotation: -90 * (1 - Ease.outCubic(p)), opacity: p) }
        entree("tourbillon", "Tourbillon") { p in let e = Ease.outCubic(p); return AnimState(scale: max(0.01, e), rotation: -360 * (1 - e)) }
        entree("flou", "Mise au point") { p in AnimState(opacity: min(1, p * 2), blur: 0.04 * (1 - p)) }
        entree("elastique", "Élastique") { p in AnimState(scale: max(0.01, Ease.outElastic(p))) }
        entree("chute", "Chute") { p in AnimState(dy: -0.7 * (1 - Ease.outBounce(p))) }
        entree("montee", "Montée") { p in AnimState(dy: 0.15 * (1 - Ease.outCubic(p)), opacity: p) }
        entree("balancement", "Balancement") { p in AnimState(rotation: 20 * (1 - p) * sin(p * .pi * 5), opacity: min(1, p * 3)) }
        entree("pop", "Pop") { p in AnimState(scale: p < 0.7 ? 1.1 * p / 0.7 : 1.1 - 0.1 * (p - 0.7) / 0.3) }
        entree("fondu-zoom", "Fondu zoomé") { p in AnimState(scale: 1.15 - 0.15 * Ease.outCubic(p), opacity: p) }
        // Sorties : p = 0 à l'état normal, 1 à la fin.
        sortie("fondu", "Fondu") { p in AnimState(opacity: 1 - p) }
        sortie("zoom-avant", "Zoom avant") { p in AnimState(scale: 1 + 0.4 * Ease.inCubic(p), opacity: 1 - p) }
        sortie("zoom-arriere", "Zoom arrière") { p in AnimState(scale: 1 - 0.4 * Ease.inCubic(p), opacity: 1 - p) }
        sortie("glisser-gauche", "Glisser vers la gauche") { p in AnimState(dx: -0.6 * Ease.inCubic(p)) }
        sortie("glisser-droite", "Glisser vers la droite") { p in AnimState(dx: 0.6 * Ease.inCubic(p)) }
        sortie("glisser-haut", "Glisser vers le haut") { p in AnimState(dy: -0.6 * Ease.inCubic(p)) }
        sortie("glisser-bas", "Glisser vers le bas") { p in AnimState(dy: 0.6 * Ease.inCubic(p)) }
        sortie("rebond", "Rebond") { p in AnimState(scale: max(0.01, 1 - Ease.outBack(p)), opacity: 1 - max(0, p - 0.7) / 0.3) }
        sortie("rotation", "Rotation") { p in AnimState(rotation: 90 * Ease.inCubic(p), opacity: 1 - p) }
        sortie("tourbillon", "Tourbillon") { p in AnimState(scale: max(0.01, 1 - p), rotation: 360 * Ease.inCubic(p)) }
        sortie("flou", "Flou") { p in AnimState(opacity: 1 - max(0, p * 2 - 1), blur: 0.04 * p) }
        sortie("chute", "Chute") { p in AnimState(dy: 0.8 * Ease.inCubic(p), rotation: 15 * p) }
        sortie("montee", "Envol") { p in AnimState(dy: -0.15 * p, opacity: 1 - p) }
        sortie("pop", "Pop") { p in AnimState(scale: p < 0.3 ? 1 + 0.1 * p / 0.3 : max(0.01, 1.1 * (1 - (p - 0.3) / 0.7))) }
        sortie("fondu-zoom", "Fondu zoomé") { p in AnimState(scale: 1 + 0.15 * p, opacity: 1 - p) }
        sortie("retrecir", "Rétrécir") { p in AnimState(scale: max(0.01, 1 - Ease.inCubic(p))) }
        // Boucles : p = phase de 0 à 1.
        boucle("secousse", "Secousse") { p in AnimState(dx: 0.01 * sin(p * 2 * .pi * 6), dy: 0.008 * cos(p * 2 * .pi * 5)) }
        boucle("balancement", "Balancement") { p in AnimState(rotation: 6 * sin(p * 2 * .pi)) }
        boucle("pulsation", "Pulsation") { p in AnimState(scale: 1 + 0.06 * sin(p * 2 * .pi)) }
        boucle("flottement", "Flottement") { p in AnimState(dy: 0.02 * sin(p * 2 * .pi)) }
        boucle("rotation", "Rotation continue") { p in AnimState(rotation: 360 * p) }
        boucle("clignotement", "Clignotement") { p in AnimState(opacity: p < 0.5 ? 1 : 0.25) }
        boucle("battement", "Battement de cœur") { p in AnimState(scale: 1 + (p < 0.15 ? 0.12 * sin(p / 0.15 * .pi) : (p < 0.35 ? 0.08 * sin((p - 0.15) / 0.2 * .pi) : 0))) }
        boucle("vague", "Vague") { p in AnimState(dx: 0.02 * sin(p * 2 * .pi), rotation: 3 * cos(p * 2 * .pi)) }
        boucle("respiration", "Respiration") { p in AnimState(scale: 1 + 0.03 * sin(p * 2 * .pi), opacity: 0.9 + 0.1 * sin(p * 2 * .pi)) }
        return list
    }
}

/// Animations propres au texte (apparition progressive, karaoké…).
struct TextAnimationDef: Identifiable {
    enum Mode { case typewriter, cursor, word, letterFade, karaoke, karaokeFill, counter, wordPop }
    let id: String
    let name: String
    let mode: Mode
    /// Multiplicateur de vitesse appliqué à la durée d'animation du texte.
    let speed: Double
}

enum TextAnimationCatalog {
    static let all: [TextAnimationDef] = {
        var list: [TextAnimationDef] = []
        let speeds: [(String, String, Double)] = [("lente", "lente", 0.5), ("normale", "", 1), ("rapide", "rapide", 2)]
        let modes: [(String, String, TextAnimationDef.Mode)] = [
            ("machine", "Machine à écrire", .typewriter),
            ("curseur", "Machine à écrire avec curseur", .cursor),
            ("mot", "Mot par mot", .word),
            ("lettre", "Lettre par lettre (fondu)", .letterFade),
            ("karaoke", "Karaoké (mot prononcé)", .karaoke),
            ("karaoke-rempli", "Karaoké (remplissage)", .karaokeFill),
            ("mot-pop", "Mots qui surgissent", .wordPop),
        ]
        for (mid, mname, mode) in modes {
            for (sid, sname, speed) in speeds {
                let name = sname.isEmpty ? mname : "\(mname), \(sname)"
                list.append(TextAnimationDef(id: "texte-\(mid)-\(sid)", name: name, mode: mode, speed: speed))
            }
        }
        list.append(TextAnimationDef(id: "texte-compteur", name: "Compteur de chiffres", mode: .counter, speed: 1))
        return list
    }()
    static let byID: [String: TextAnimationDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
