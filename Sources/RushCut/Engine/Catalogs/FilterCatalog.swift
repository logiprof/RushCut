import Foundation
import CoreImage

/// Recette d'un filtre de couleur (combinaison de réglages Core Image).
struct FilterRecipe {
    var warmth = 0.0
    var tint = 0.0
    var saturation = 0.0
    var contrast = 0.0
    var brightness = 0.0
    var exposure = 0.0
    var vibrance = 0.0
    var fade = 0.0
    var sepia = 0.0
    var vignette = 0.0
    var grain = 0.0
    var photoEffect: String? = nil
    var duotone: (RGBA, RGBA)? = nil
    var monochrome: RGBA? = nil
    var posterize = 0.0
}

struct FilterDef: Identifiable {
    let id: String
    let name: String
    let category: String
    let recipe: FilterRecipe
}

/// 60 filtres originaux (aucune ressource de CapCut n'est utilisée).
enum FilterCatalog {
    static let all: [FilterDef] = build()
    static let byID: [String: FilterDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static var categories: [String] { var seen: [String] = []; for f in all where !seen.contains(f.category) { seen.append(f.category) }; return seen }

    static func apply(_ ref: FilterRef, to image: CIImage, frame: Int) -> CIImage {
        guard let def = byID[ref.id] else { return image }
        return CI.mix(image, render(def.recipe, image, frame: frame), amount: ref.intensity)
    }

    static func render(_ r: FilterRecipe, _ input: CIImage, frame: Int) -> CIImage {
        let e = input.extent
        var image = input
        if let effect = r.photoEffect { image = image.applyingFilter(effect) }
        if r.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure]) }
        if r.saturation != 0 || r.contrast != 0 || r.brightness != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: max(0, 1 + r.saturation),
                kCIInputContrastKey: 1 + r.contrast,
                kCIInputBrightnessKey: r.brightness,
            ])
        }
        if r.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": r.vibrance]) }
        image = CI.temperature(image, warmth: r.warmth, tint: r.tint)
        if r.sepia > 0 { image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: r.sepia]) }
        if let mono = r.monochrome {
            image = image.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CI.color(mono), kCIInputIntensityKey: 1])
        }
        if let duo = r.duotone {
            image = image.applyingFilter("CIFalseColor", parameters: ["inputColor0": CI.color(duo.0), "inputColor1": CI.color(duo.1)])
        }
        if r.posterize > 0 { image = image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": max(2, 12 - 9 * r.posterize)]) }
        image = CI.fade(image.cropped(to: e), amount: r.fade)
        image = CI.vignette(image, amount: r.vignette)
        image = CI.grain(image, amount: r.grain, frame: frame)
        return image.cropped(to: e)
    }

    private static func build() -> [FilterDef] {
        var list: [FilterDef] = []
        func add(_ id: String, _ name: String, _ category: String, _ r: FilterRecipe) {
            list.append(FilterDef(id: id, name: name, category: category, recipe: r))
        }
        // Naturels
        add("naturel", "Naturel", "Naturel", FilterRecipe(saturation: 0.08, contrast: 0.06, vibrance: 0.2))
        add("eclat", "Éclat", "Naturel", FilterRecipe(saturation: 0.15, contrast: 0.1, brightness: 0.03, vibrance: 0.3))
        add("doux", "Doux", "Naturel", FilterRecipe(saturation: -0.1, contrast: -0.12, brightness: 0.03, fade: 0.3))
        add("clair", "Clair", "Naturel", FilterRecipe(contrast: -0.05, exposure: 0.35, vibrance: 0.1))
        add("vif", "Vif", "Naturel", FilterRecipe(saturation: 0.35, contrast: 0.15, vibrance: 0.3))
        add("mat", "Mat", "Naturel", FilterRecipe(saturation: -0.15, contrast: -0.1, fade: 0.5))
        add("pastel", "Pastel", "Naturel", FilterRecipe(saturation: -0.25, brightness: 0.06, fade: 0.45))
        add("profond", "Profond", "Naturel", FilterRecipe(saturation: 0.1, contrast: 0.3, exposure: -0.2))
        // Chaud / froid
        for (i, w) in [0.25, 0.45, 0.7].enumerated() {
            add("chaud\(i + 1)", "Chaud \(i + 1)", "Chaud et froid", FilterRecipe(warmth: w, saturation: 0.05 * Double(i + 1)))
            add("froid\(i + 1)", "Froid \(i + 1)", "Chaud et froid", FilterRecipe(warmth: -w, saturation: -0.03 * Double(i + 1)))
        }
        add("dore", "Heure dorée", "Chaud et froid", FilterRecipe(warmth: 0.6, tint: 0.1, saturation: 0.15, contrast: 0.05, fade: 0.1))
        add("bleu-nuit", "Bleu nuit", "Chaud et froid", FilterRecipe(warmth: -0.8, saturation: -0.1, contrast: 0.1, exposure: -0.4))
        add("menthe", "Menthe", "Chaud et froid", FilterRecipe(warmth: -0.2, tint: -0.4, saturation: -0.05, fade: 0.2))
        add("rose", "Rosé", "Chaud et froid", FilterRecipe(warmth: 0.15, tint: 0.45, fade: 0.15))
        // Noir et blanc
        add("nb", "Noir et blanc", "Noir et blanc", FilterRecipe(photoEffect: "CIPhotoEffectMono"))
        add("nb-contraste", "N&B contrasté", "Noir et blanc", FilterRecipe(contrast: 0.35, photoEffect: "CIPhotoEffectNoir"))
        add("nb-doux", "N&B doux", "Noir et blanc", FilterRecipe(contrast: -0.1, fade: 0.35, photoEffect: "CIPhotoEffectTonal"))
        add("nb-grain", "N&B argentique", "Noir et blanc", FilterRecipe(contrast: 0.2, grain: 0.6, photoEffect: "CIPhotoEffectMono"))
        add("selenium", "Sélénium", "Noir et blanc", FilterRecipe(monochrome: RGBA(r: 0.55, g: 0.5, b: 0.62)))
        add("cyanotype", "Cyanotype", "Noir et blanc", FilterRecipe(monochrome: RGBA(r: 0.2, g: 0.45, b: 0.75)))
        // Vintage
        add("sepia", "Sépia", "Vintage", FilterRecipe(sepia: 0.85))
        add("instantane", "Instantané", "Vintage", FilterRecipe(photoEffect: "CIPhotoEffectInstant"))
        add("delave", "Délavé", "Vintage", FilterRecipe(photoEffect: "CIPhotoEffectFade"))
        add("transfert", "Transfert", "Vintage", FilterRecipe(photoEffect: "CIPhotoEffectTransfer"))
        add("chrome", "Chrome", "Vintage", FilterRecipe(photoEffect: "CIPhotoEffectChrome"))
        add("process", "Tirage", "Vintage", FilterRecipe(photoEffect: "CIPhotoEffectProcess"))
        add("annees70", "Années 70", "Vintage", FilterRecipe(warmth: 0.45, saturation: -0.1, fade: 0.35, grain: 0.3))
        add("annees80", "Années 80", "Vintage", FilterRecipe(tint: 0.25, saturation: 0.25, contrast: 0.1, fade: 0.2))
        add("annees90", "Années 90", "Vintage", FilterRecipe(warmth: 0.1, tint: -0.15, saturation: -0.05, fade: 0.25, grain: 0.2))
        add("polaroid", "Polaroïd", "Vintage", FilterRecipe(warmth: 0.25, contrast: -0.1, fade: 0.4, vignette: 0.4))
        add("vieux-film", "Vieux film", "Vintage", FilterRecipe(fade: 0.3, sepia: 0.4, vignette: 0.8, grain: 0.7))
        // Cinéma
        add("cinema", "Cinéma", "Cinéma", FilterRecipe(warmth: 0.15, saturation: -0.1, contrast: 0.2, vignette: 0.3))
        add("sarcelle-orange", "Sarcelle et orange", "Cinéma", FilterRecipe(warmth: 0.3, tint: -0.2, saturation: 0.1, contrast: 0.25))
        add("thriller", "Thriller", "Cinéma", FilterRecipe(warmth: -0.35, tint: -0.2, saturation: -0.3, contrast: 0.3))
        add("western", "Western", "Cinéma", FilterRecipe(warmth: 0.7, saturation: -0.2, contrast: 0.2, fade: 0.1, grain: 0.2))
        add("noir-film", "Film noir", "Cinéma", FilterRecipe(contrast: 0.5, vignette: 0.9, photoEffect: "CIPhotoEffectNoir"))
        add("blockbuster", "Blockbuster", "Cinéma", FilterRecipe(warmth: 0.2, saturation: 0.15, contrast: 0.35, exposure: -0.1))
        add("reve", "Rêve", "Cinéma", FilterRecipe(tint: 0.2, saturation: -0.1, brightness: 0.05, fade: 0.4))
        add("science-fiction", "Science-fiction", "Cinéma", FilterRecipe(warmth: -0.6, tint: -0.3, contrast: 0.25))
        // Portrait
        add("portrait", "Portrait", "Portrait", FilterRecipe(warmth: 0.1, saturation: -0.05, contrast: -0.05, brightness: 0.03))
        add("peau-douce", "Peau douce", "Portrait", FilterRecipe(warmth: 0.15, tint: 0.1, contrast: -0.15, fade: 0.15))
        add("studio", "Studio", "Portrait", FilterRecipe(saturation: 0.05, contrast: 0.15, exposure: 0.15))
        add("bronze", "Bronzé", "Portrait", FilterRecipe(warmth: 0.4, saturation: 0.1, contrast: 0.1))
        // Paysage
        add("paysage", "Paysage", "Paysage", FilterRecipe(saturation: 0.25, contrast: 0.1, vibrance: 0.4))
        add("foret", "Forêt", "Paysage", FilterRecipe(warmth: -0.1, tint: -0.2, saturation: 0.2, contrast: 0.1))
        add("ocean", "Océan", "Paysage", FilterRecipe(warmth: -0.35, saturation: 0.25, vibrance: 0.3))
        add("automne", "Automne", "Paysage", FilterRecipe(warmth: 0.5, tint: 0.1, saturation: 0.2))
        add("hiver", "Hiver", "Paysage", FilterRecipe(warmth: -0.5, saturation: -0.3, brightness: 0.05))
        // Nourriture
        add("gourmand", "Gourmand", "Nourriture", FilterRecipe(warmth: 0.25, saturation: 0.25, contrast: 0.1))
        add("frais", "Frais", "Nourriture", FilterRecipe(warmth: -0.1, saturation: 0.2, exposure: 0.15, vibrance: 0.3))
        // Nuit
        add("nuit", "Nuit", "Nuit", FilterRecipe(warmth: -0.4, saturation: -0.15, contrast: 0.2, exposure: -0.3))
        add("neon", "Néon", "Nuit", FilterRecipe(tint: 0.35, saturation: 0.5, contrast: 0.3))
        add("ville", "Ville la nuit", "Nuit", FilterRecipe(warmth: -0.2, tint: 0.15, saturation: 0.2, contrast: 0.25, vignette: 0.4))
        // Créatifs
        add("bichromie-bleu", "Bichromie bleue", "Créatifs", FilterRecipe(duotone: (RGBA(r: 0.05, g: 0.05, b: 0.3), RGBA(r: 0.6, g: 0.85, b: 1))))
        add("bichromie-rose", "Bichromie rose", "Créatifs", FilterRecipe(duotone: (RGBA(r: 0.25, g: 0.02, b: 0.2), RGBA(r: 1, g: 0.6, b: 0.75))))
        add("bichromie-or", "Bichromie or", "Créatifs", FilterRecipe(duotone: (RGBA(r: 0.15, g: 0.08, b: 0.02), RGBA(r: 1, g: 0.85, b: 0.45))))
        add("pop", "Pop", "Créatifs", FilterRecipe(saturation: 0.6, contrast: 0.3, posterize: 0.5))
        add("affiche", "Affiche", "Créatifs", FilterRecipe(contrast: 0.3, posterize: 0.8))
        return list
    }
}
