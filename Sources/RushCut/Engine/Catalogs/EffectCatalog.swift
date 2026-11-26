import Foundation
import CoreImage
import CoreGraphics

/// Contexte d'application d'un effet à une image.
struct EffectContext {
    /// Temps écoulé depuis le début du clip, en secondes.
    var local: Double
    var duration: Double
    /// Numéro d'image (pour les effets aléatoires, identiques à l'aperçu et à l'export).
    var frame: Int
    var intensity: Double
    var params: [String: Double]
    /// Taille du cadre de rendu (les tailles des effets en dépendent).
    var canvas: CGSize
    /// Zone visée (fractions du cadre, origine en haut à gauche) pour les effets localisés.
    var region: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

    func param(_ key: String, _ fallback: Double) -> Double { params[key] ?? fallback }
}

enum EffectCategory: String, CaseIterable {
    case lumiere = "Lumière", flou = "Flou", glitch = "Glitch", mouvement = "Mouvement de caméra"
    case retro = "Rétro et film", distorsion = "Distorsion", particules = "Particules", cadres = "Cadres et écrans"
    case tutoriel = "Tutoriel", stylisation = "Stylisation", corps = "Effets sur le corps", saisons = "Saisonniers et fêtes"
}

struct EffectDef: Identifiable {
    let id: String
    let name: String
    let category: EffectCategory
    /// Modifie l'image (effet visuel).
    var image: ((CIImage, EffectContext) -> CIImage)? = nil
    /// Modifie la position du calque (mouvements de caméra).
    var camera: ((EffectContext) -> AnimState)? = nil
    /// Nécessite le détourage de la personne (lot V2).
    var needsSegmentation = false
}

/// Bibliothèque d'effets originaux. Chaque effet est une recette Core Image (aucune ressource de CapCut).
enum EffectCatalog {
    static let all: [EffectDef] = build()
    static let byID: [String: EffectDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func list(_ category: EffectCategory) -> [EffectDef] { all.filter { $0.category == category } }

    static func apply(_ effects: [EffectInstance], to image: CIImage, context: EffectContext) -> CIImage {
        var result = image
        for e in effects {
            guard let def = byID[e.type], let f = def.image else { continue }
            var ctx = context
            ctx.intensity = e.intensity
            ctx.params = e.params
            result = CI.mix(result, f(result, ctx).cropped(to: result.extent), amount: e.intensity)
        }
        return result
    }

    static func camera(_ effects: [EffectInstance], context: EffectContext) -> AnimState {
        var state = AnimState.identity
        for e in effects {
            guard let def = byID[e.type], let f = def.camera else { continue }
            var ctx = context
            ctx.intensity = e.intensity
            ctx.params = e.params
            state = state.combined(with: f(ctx))
        }
        return state
    }

    // MARK: - Construction

    private static func build() -> [EffectDef] {
        var list: [EffectDef] = []
        func img(_ id: String, _ name: String, _ cat: EffectCategory, segmentation: Bool = false,
                 _ f: @escaping (CIImage, EffectContext) -> CIImage) {
            list.append(EffectDef(id: id, name: name, category: cat, image: f, needsSegmentation: segmentation))
        }
        func cam(_ id: String, _ name: String, _ f: @escaping (EffectContext) -> AnimState) {
            list.append(EffectDef(id: id, name: name, category: .mouvement, camera: f))
        }

        // MARK: Lumière (20)
        let leaks: [(String, String, RGBA)] = [
            ("chaude", "Fuite de lumière chaude", RGBA(r: 1, g: 0.55, b: 0.15)),
            ("froide", "Fuite de lumière froide", RGBA(r: 0.3, g: 0.6, b: 1)),
            ("rose", "Fuite de lumière rose", RGBA(r: 1, g: 0.35, b: 0.6)),
            ("doree", "Fuite de lumière dorée", RGBA(r: 1, g: 0.8, b: 0.3)),
        ]
        for (id, name, color) in leaks {
            img("lumiere-fuite-\(id)", name, .lumiere) { i, c in Light.leak(i, c, color: color) }
        }
        let flares: [(String, String, RGBA)] = [
            ("1", "Reflet d'objectif", RGBA(r: 1, g: 0.9, b: 0.7)),
            ("2", "Reflet bleuté", RGBA(r: 0.6, g: 0.8, b: 1)),
        ]
        for (id, name, color) in flares {
            img("lumiere-reflet-\(id)", name, .lumiere) { i, c in Light.sunbeams(i, c, color: color, moving: true) }
        }
        img("lumiere-rayons", "Rayons", .lumiere) { i, c in Light.sunbeams(i, c, color: RGBA(r: 1, g: 0.95, b: 0.8), moving: false) }
        img("lumiere-rayons-dores", "Rayons dorés", .lumiere) { i, c in Light.sunbeams(i, c, color: RGBA(r: 1, g: 0.75, b: 0.3), moving: false) }
        let halos: [(String, Double)] = [("Halo léger", 0.5), ("Halo", 1.0), ("Halo intense", 1.8)]
        for (n, s) in halos {
            img("lumiere-halo-\(Int(s * 10))", n, .lumiere) { i, c in
                i.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: c.canvas.height * 0.02 * s, kCIInputIntensityKey: 0.8 * s])
            }
        }
        img("lumiere-bokeh", "Bokeh", .lumiere) { i, c in Particles.overlay(i, c, kind: .bokeh, count: 26, color: RGBA(r: 1, g: 0.9, b: 0.7, a: 0.35)) }
        img("lumiere-bokeh-couleur", "Bokeh coloré", .lumiere) { i, c in Particles.overlay(i, c, kind: .bokeh, count: 30, color: nil) }
        img("lumiere-flash", "Flash", .lumiere) { i, c in Light.flash(i, c, period: 1.2) }
        img("lumiere-flash-rapide", "Flash rapide", .lumiere) { i, c in Light.flash(i, c, period: 0.4) }
        img("lumiere-scintillement", "Scintillement", .lumiere) { i, c in
            i.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: (CI.random(c.frame / 2) - 0.5) * 0.6])
        }
        img("lumiere-scintillement-doux", "Scintillement doux", .lumiere) { i, c in
            i.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: CI.smoothNoise(c.local * 4, seed: 3) * 0.25])
        }
        let neons: [(String, String, RGBA)] = [
            ("rose", "Néon rose", RGBA(r: 1, g: 0.2, b: 0.8)),
            ("bleu", "Néon bleu", RGBA(r: 0.2, g: 0.6, b: 1)),
            ("vert", "Néon vert", RGBA(r: 0.3, g: 1, b: 0.4)),
        ]
        for (id, name, color) in neons {
            img("lumiere-neon-\(id)", name, .lumiere) { i, c in Light.neon(i, c, color: color) }
        }
        img("lumiere-lueur-douce", "Lueur douce", .lumiere) { i, c in
            i.applyingFilter("CIGloom", parameters: [kCIInputRadiusKey: c.canvas.height * 0.02, kCIInputIntensityKey: -0.6])
        }

        // MARK: Flou (12)
        img("flou-leger", "Flou léger", .flou) { i, c in i.clampedToExtent().applyingGaussianBlur(sigma: c.canvas.height * 0.006) }
        img("flou-fort", "Flou fort", .flou) { i, c in i.clampedToExtent().applyingGaussianBlur(sigma: c.canvas.height * 0.025) }
        img("flou-radial", "Flou radial", .flou) { i, c in
            i.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputAmountKey: c.canvas.height * 0.02])
        }
        img("flou-zoom", "Flou zoom pulsé", .flou) { i, c in
            let a = (1 + sin(c.local * 2 * .pi)) / 2 * c.canvas.height * 0.03
            return i.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputAmountKey: a])
        }
        img("flou-mouvement-h", "Flou de mouvement horizontal", .flou) { i, c in
            i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: c.canvas.height * 0.02, kCIInputAngleKey: 0])
        }
        img("flou-mouvement-v", "Flou de mouvement vertical", .flou) { i, c in
            i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: c.canvas.height * 0.02, kCIInputAngleKey: Double.pi / 2])
        }
        img("flou-tilt-shift", "Tilt-shift (maquette)", .flou) { i, c in Blur.tiltShift(i, c) }
        img("flou-bords", "Bords flous", .flou) { i, c in Blur.vignetteBlur(i, c) }
        img("flou-boite", "Flou carré", .flou) { i, c in i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: c.canvas.height * 0.02]) }
        img("flou-disque", "Flou d'objectif", .flou) { i, c in i.clampedToExtent().applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: c.canvas.height * 0.015]) }
        img("flou-reve", "Flou de rêve", .flou) { i, c in
            CI.mix(i, i.clampedToExtent().applyingGaussianBlur(sigma: c.canvas.height * 0.02).cropped(to: i.extent)
                .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: i]), amount: 0.6)
        }
        img("flou-entree", "Mise au point progressive", .flou) { i, c in
            let s = max(0, 1 - c.local / max(0.3, min(1.5, c.duration))) * c.canvas.height * 0.03
            return s < 0.5 ? i : i.clampedToExtent().applyingGaussianBlur(sigma: s)
        }

        // MARK: Glitch (20)
        let splits: [(String, Double)] = [("Décalage RVB léger", 0.4), ("Décalage RVB", 1.0), ("Décalage RVB fort", 2.0)]
        for (n, s) in splits {
            img("glitch-rvb-\(Int(s * 10))", n, .glitch) { i, c in Glitch.rgbSplit(i, c, strength: s, animated: false) }
        }
        img("glitch-rvb-anime", "Décalage RVB animé", .glitch) { i, c in Glitch.rgbSplit(i, c, strength: 1.2, animated: true) }
        img("glitch-lignes", "Lignes de balayage", .glitch) { i, c in Glitch.scanlines(i, c, opacity: 0.25) }
        img("glitch-vhs", "VHS", .glitch) { i, c in Glitch.vhs(i, c) }
        img("glitch-pixels", "Pixels cassés", .glitch) { i, c in Glitch.blocks(i, c) }
        img("glitch-compression", "Compression", .glitch) { i, c in
            i.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, c.canvas.height * 0.012), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .applyingFilter("CIColorPosterize", parameters: ["inputLevels": 8])
        }
        img("glitch-tv", "Vieille télévision", .glitch) { i, c in
            CI.vignette(Glitch.scanlines(i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.7, kCIInputContrastKey: 1.2]), c, opacity: 0.35), amount: 1)
        }
        img("glitch-hologramme", "Hologramme", .glitch) { i, c in Glitch.hologram(i, c) }
        img("glitch-saccade", "Saccades", .glitch) { i, c in Glitch.jitter(i, c) }
        img("glitch-bruit", "Bruit numérique", .glitch) { i, c in CI.grain(i, amount: 1, frame: c.frame) }
        img("glitch-inversion", "Inversion flash", .glitch) { i, c in
            Int(c.local * 3) % 4 == 0 && CI.random(Int(c.local * 3)) > 0.4 ? i.applyingFilter("CIColorInvert") : i
        }
        img("glitch-couleur", "Glitch couleur", .glitch) { i, c in
            i.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: CI.random(c.frame / 3) > 0.7 ? CI.random(c.frame / 3, 5) * 6 : 0])
        }
        img("glitch-bandes", "Bandes", .glitch) { i, c in Glitch.bands(i, c) }
        img("glitch-dechirure", "Déchirure", .glitch) { i, c in Glitch.tear(i, c) }
        img("glitch-signal", "Perte de signal", .glitch) { i, c in Glitch.signalLoss(i, c) }
        img("glitch-cyber", "Cyber", .glitch) { i, c in Glitch.scanlines(Glitch.rgbSplit(i, c, strength: 1.5, animated: true), c, opacity: 0.2) }
        img("glitch-negatif", "Négatif", .glitch) { i, _ in i.applyingFilter("CIColorInvert") }
        img("glitch-matrice", "Matrice", .glitch) { i, c in
            Glitch.scanlines(i.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CIColor(red: 0.1, green: 1, blue: 0.3)]), c, opacity: 0.3)
        }

        // MARK: Mouvement de caméra (20)
        cam("camera-secousse-legere", "Secousse légère") { c in Shake.state(c, amount: 0.006, speed: 14) }
        cam("camera-secousse", "Secousse") { c in Shake.state(c, amount: 0.015, speed: 18) }
        cam("camera-secousse-forte", "Secousse forte") { c in Shake.state(c, amount: 0.03, speed: 22) }
        cam("camera-epaule", "Caméra à l'épaule") { c in Shake.state(c, amount: 0.008, speed: 1.6) }
        cam("camera-zoom-percutant", "Zoom percutant") { c in
            let p = min(1, c.local / 0.25)
            return AnimState(scale: 1 + 0.25 * (1 - Ease.outCubic(p)))
        }
        cam("camera-zoom-battement", "Zoom au rythme") { c in AnimState(scale: 1 + 0.08 * max(0, 1 - (c.local.truncatingRemainder(dividingBy: 0.5)) / 0.25)) }
        cam("camera-zoom-lent-avant", "Zoom lent avant") { c in AnimState(scale: 1 + 0.15 * min(1, c.local / max(0.1, c.duration))) }
        cam("camera-zoom-lent-arriere", "Zoom lent arrière") { c in AnimState(scale: 1.15 - 0.15 * min(1, c.local / max(0.1, c.duration))) }
        cam("camera-panoramique-gauche", "Panoramique rapide gauche") { c in AnimState(dx: -0.3 * pow(max(0, 1 - c.local / 0.4), 2)) }
        cam("camera-panoramique-droite", "Panoramique rapide droite") { c in AnimState(dx: 0.3 * pow(max(0, 1 - c.local / 0.4), 2)) }
        cam("camera-rebond", "Rebond") { c in AnimState(dy: -0.03 * abs(sin(c.local * .pi * 2))) }
        cam("camera-vertige", "Vertige") { c in AnimState(scale: 1.1 + 0.05 * sin(c.local * 2), rotation: 3 * sin(c.local * 1.5)) }
        cam("camera-balancement", "Balancement") { c in AnimState(rotation: 2.5 * sin(c.local * 2.5)) }
        cam("camera-roulis", "Roulis") { c in AnimState(dx: 0.01 * sin(c.local * 1.7), rotation: 4 * sin(c.local * 1.2)) }
        cam("camera-derive", "Dérive") { c in AnimState(dx: 0.04 * (c.local / max(0.1, c.duration) - 0.5), scale: 1.08) }
        cam("camera-tourbillon", "Tourbillon") { c in AnimState(scale: 1.2, rotation: 25 * sin(c.local * 3)) }
        cam("camera-choc", "Choc") { c in
            let p = c.local.truncatingRemainder(dividingBy: 1)
            return AnimState(dx: p < 0.15 ? 0.02 * sin(p * 120) : 0, scale: p < 0.1 ? 1.06 : 1)
        }
        cam("camera-elastique", "Élastique") { c in AnimState(scale: 1 + 0.06 * sin(c.local * 8) * exp(-c.local * 2)) }
        cam("camera-respiration", "Respiration") { c in AnimState(scale: 1.03 + 0.03 * sin(c.local * 1.5)) }
        cam("camera-trembler", "Tremblement") { c in Shake.state(c, amount: 0.004, speed: 30) }

        // MARK: Rétro et film (15)
        img("retro-grain", "Grain de film", .retro) { i, c in CI.grain(i, amount: 0.7, frame: c.frame) }
        img("retro-poussiere", "Poussière", .retro) { i, c in Particles.overlay(i, c, kind: .dust, count: 60, color: RGBA(r: 1, g: 1, b: 1, a: 0.7)) }
        img("retro-rayures", "Rayures", .retro) { i, c in Retro.scratches(i, c) }
        img("retro-8mm", "Film 8 mm", .retro) { i, c in Retro.film(i, c, sepia: 0.3, warmth: 0.4) }
        img("retro-sepia", "Sépia", .retro) { i, _ in i.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.9]) }
        img("retro-muet", "Cinéma muet", .retro) { i, c in
            Retro.film(i.applyingFilter("CIPhotoEffectNoir").applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: CI.smoothNoise(c.local * 8, seed: 9) * 0.2]), c, sepia: 0, warmth: 0)
        }
        img("retro-polaroid", "Polaroïd", .retro) { i, _ in CI.vignette(CI.fade(i.applyingFilter("CIPhotoEffectInstant"), amount: 0.4), amount: 0.5) }
        img("retro-vieux-film", "Vieux film", .retro) { i, c in Retro.scratches(Retro.film(i, c, sepia: 0.7, warmth: 0.2), c) }
        img("retro-70", "Années 70", .retro) { i, c in CI.grain(CI.fade(CI.temperature(i, warmth: 0.5, tint: 0.05), amount: 0.4), amount: 0.3, frame: c.frame) }
        img("retro-80", "Années 80", .retro) { i, c in Glitch.scanlines(CI.temperature(i, warmth: -0.1, tint: 0.3), c, opacity: 0.12) }
        img("retro-90", "Années 90", .retro) { i, c in Glitch.vhs(CI.fade(i, amount: 0.25), c) }
        img("retro-nb", "Noir et blanc contrasté", .retro) { i, _ in i.applyingFilter("CIPhotoEffectNoir").applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.3]) }
        img("retro-bichromie", "Bichromie", .retro) { i, _ in
            i.applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(red: 0.1, green: 0.05, blue: 0.2), "inputColor1": CIColor(red: 1, green: 0.8, blue: 0.5)])
        }
        img("retro-vhs-doux", "VHS doux", .retro) { i, c in CI.mix(i, Glitch.vhs(i, c), amount: 0.5) }
        img("retro-daguerreotype", "Daguerréotype", .retro) { i, c in
            CI.vignette(CI.grain(i.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CIColor(red: 0.6, green: 0.55, blue: 0.45)]), amount: 0.8, frame: c.frame), amount: 1.5)
        }

        // MARK: Distorsion (15)
        img("distorsion-fisheye", "Fish-eye", .distorsion) { i, c in Distort.bump(i, c, radius: 0.9, scale: 0.6) }
        img("distorsion-loupe", "Loupe", .distorsion) { i, c in Distort.bump(i, c, radius: 0.35, scale: 0.8) }
        img("distorsion-pincement", "Pincement", .distorsion) { i, c in
            i.clampedToExtent().applyingFilter("CIPinchDistortion", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputRadiusKey: i.extent.height * 0.6, kCIInputScaleKey: 0.5])
        }
        img("distorsion-tourbillon", "Tourbillon", .distorsion) { i, c in
            i.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputRadiusKey: i.extent.height * 0.5, kCIInputAngleKey: 2.5 * sin(c.local)])
        }
        img("distorsion-vortex", "Vortex", .distorsion) { i, c in
            i.clampedToExtent().applyingFilter("CIVortexDistortion", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputRadiusKey: i.extent.height * 0.45, kCIInputAngleKey: 40 * sin(c.local * 0.8)])
        }
        img("distorsion-ondulation", "Ondulation", .distorsion) { i, c in Distort.wave(i, c, amplitude: 0.01, frequency: 6) }
        img("distorsion-vague", "Vague", .distorsion) { i, c in Distort.wave(i, c, amplitude: 0.025, frequency: 2) }
        img("distorsion-miroir-h", "Miroir horizontal", .distorsion) { i, _ in Distort.mirror(i, vertical: false) }
        img("distorsion-miroir-v", "Miroir vertical", .distorsion) { i, _ in Distort.mirror(i, vertical: true) }
        img("distorsion-kaleidoscope", "Kaléidoscope", .distorsion) { i, c in
            i.applyingFilter("CIKaleidoscope", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), "inputCount": 6, kCIInputAngleKey: c.local * 0.3])
        }
        img("distorsion-triangles", "Kaléidoscope triangles", .distorsion) { i, c in
            i.applyingFilter("CITriangleKaleidoscope", parameters: ["inputPoint": CIVector(x: i.extent.midX, y: i.extent.midY), "inputSize": i.extent.height * 0.4, "inputRotation": c.local * 0.3, "inputDecay": 0.85])
        }
        img("distorsion-verre", "Verre", .distorsion) { i, c in
            i.clampedToExtent().applyingFilter("CIGlassLozenge", parameters: ["inputPoint0": CIVector(x: i.extent.width * 0.3, y: i.extent.midY), "inputPoint1": CIVector(x: i.extent.width * 0.7, y: i.extent.midY), kCIInputRadiusKey: i.extent.height * 0.25, "inputRefraction": 1.7])
        }
        img("distorsion-mosaique", "Mosaïque", .distorsion) { i, c in
            i.applyingFilter("CIHexagonalPixellate", parameters: [kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputScaleKey: max(6, c.canvas.height * 0.02)])
        }
        img("distorsion-cristal", "Cristal", .distorsion) { i, c in
            i.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: max(6, c.canvas.height * 0.02), kCIInputCenterKey: CIVector(x: 0, y: 0)])
        }
        img("distorsion-carreaux", "Carreaux", .distorsion) { i, c in
            i.applyingFilter("CIOpTile", parameters: [kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputScaleKey: 2.8, kCIInputAngleKey: 0, kCIInputWidthKey: i.extent.height * 0.3])
        }

        // MARK: Particules (20)
        let particles: [(String, String, Particles.Kind, Int, RGBA?)] = [
            ("neige", "Neige", .snow, 120, .white), ("neige-dense", "Neige dense", .snow, 260, .white),
            ("pluie", "Pluie", .rain, 160, RGBA(r: 0.8, g: 0.85, b: 1, a: 0.6)), ("orage", "Pluie d'orage", .rain, 320, RGBA(r: 0.75, g: 0.8, b: 1, a: 0.7)),
            ("confettis", "Confettis", .confetti, 140, nil), ("etincelles", "Étincelles", .sparkle, 70, RGBA(r: 1, g: 0.85, b: 0.4)),
            ("coeurs", "Cœurs", .heart, 40, RGBA(r: 1, g: 0.3, b: 0.45)), ("etoiles", "Étoiles", .star, 50, RGBA(r: 1, g: 0.9, b: 0.3)),
            ("fumee", "Fumée", .smoke, 18, RGBA(r: 0.85, g: 0.85, b: 0.85, a: 0.18)), ("poussiere-doree", "Poussière dorée", .dust, 150, RGBA(r: 1, g: 0.8, b: 0.35, a: 0.9)),
            ("bulles", "Bulles", .bubble, 45, RGBA(r: 0.8, g: 0.95, b: 1, a: 0.8)), ("lucioles", "Lucioles", .firefly, 40, RGBA(r: 0.9, g: 1, b: 0.4)),
            ("petales", "Pétales", .petal, 50, RGBA(r: 1, g: 0.7, b: 0.8)), ("flocons", "Gros flocons", .flake, 50, .white),
            ("paillettes", "Paillettes", .sparkle, 160, nil), ("cendres", "Cendres", .dust, 90, RGBA(r: 1, g: 0.5, b: 0.2, a: 0.9)),
            ("notes", "Notes de musique", .note, 25, .white), ("points", "Points lumineux", .bokeh, 60, RGBA(r: 1, g: 1, b: 1, a: 0.5)),
            ("pieces", "Pluie de pièces", .coin, 40, RGBA(r: 1, g: 0.8, b: 0.2)), ("feu-artifice", "Feu d'artifice", .firework, 5, nil),
        ]
        for (id, name, kind, count, color) in particles {
            img("particules-\(id)", name, .particules) { i, c in
                Particles.overlay(i, c, kind: kind, count: Int(Double(count) * c.param("densite", 1)), color: color)
            }
        }

        // MARK: Cadres et écrans (15) + tutoriel
        for frame in Frames.all {
            img("cadre-\(frame.id)", frame.name, .cadres) { i, c in Frames.apply(frame, to: i, context: c) }
        }
        img("tutoriel-projecteur", "Projecteur", .tutoriel) { i, c in Tutorial.spotlight(i, c) }
        img("tutoriel-loupe", "Loupe sur zone", .tutoriel) { i, c in Tutorial.magnifier(i, c) }
        img("tutoriel-floutage", "Floutage de zone", .tutoriel) { i, c in Tutorial.blurRegion(i, c, pixelate: false) }
        img("tutoriel-pixellisation", "Pixellisation de zone", .tutoriel) { i, c in Tutorial.blurRegion(i, c, pixelate: true) }
        img("tutoriel-surligneur", "Surligneur de zone", .tutoriel) { i, c in Tutorial.highlight(i, c) }

        // MARK: Stylisation (lot V2, 20)
        list.append(contentsOf: Stylize.effects())
        // MARK: Saisonniers et fêtes (lot V2, 15)
        list.append(contentsOf: Seasonal.effects())
        return list
    }
}
