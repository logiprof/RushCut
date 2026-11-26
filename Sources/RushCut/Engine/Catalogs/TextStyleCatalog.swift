import Foundation

struct TextStyleDef: Identifiable {
    let id: String
    let name: String
    let category: String
    let content: TextContent
}

/// 50 styles de texte originaux, construits avec les polices livrées avec macOS.
enum TextStyleCatalog {
    static let all: [TextStyleDef] = build()

    private static func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }

    private struct S {
        var font = "Helvetica Neue"
        var size = 0.08
        var color = RGBA.white
        var bold = true
        var italic = false
        var stroke: (RGBA, Double)? = nil
        var shadow: (RGBA, Double, Double)? = nil
        var background: (RGBA, Double, Double)? = nil
        var spacing = 0.0
        var sample: String? = nil
    }

    private static func make(_ name: String, _ s: S) -> TextContent {
        var t = TextContent()
        t.string = s.sample ?? name
        t.fontName = s.font
        t.fontSize = s.size
        t.color = s.color
        t.bold = s.bold
        t.italic = s.italic
        t.letterSpacing = s.spacing
        if let st = s.stroke { t.strokeEnabled = true; t.strokeColor = st.0; t.strokeWidth = st.1 }
        if let sh = s.shadow { t.shadowEnabled = true; t.shadowColor = sh.0; t.shadowBlur = sh.1; t.shadowOffset = sh.2 }
        if let bg = s.background {
            t.backgroundEnabled = true; t.backgroundColor = bg.0; t.backgroundPadding = bg.1; t.backgroundCornerRadius = bg.2
        }
        return t
    }

    private static func build() -> [TextStyleDef] {
        var list: [TextStyleDef] = []
        func add(_ category: String, _ name: String, _ s: S) {
            let id = "style-\(list.count + 1)"
            list.append(TextStyleDef(id: id, name: name, category: category, content: make(name, s)))
        }
        let black = c(0, 0, 0), white = RGBA.white
        let yellow = c(1, 0.85, 0.1), pink = c(1, 0.3, 0.6), cyan = c(0.2, 0.9, 1), lime = c(0.6, 1, 0.2)
        let orange = c(1, 0.5, 0.1), red = c(0.95, 0.15, 0.2), violet = c(0.6, 0.3, 1), blue = c(0.15, 0.4, 1)

        // Basiques
        add("Basiques", "Titre", S(size: 0.1, shadow: (c(0, 0, 0, 0.7), 0.15, 0.05)))
        add("Basiques", "Sous-titre", S(size: 0.055, bold: false))
        add("Basiques", "Légende", S(size: 0.045, bold: false, background: (c(0, 0, 0, 0.6), 0.3, 0.2)))
        add("Basiques", "Contour noir", S(size: 0.09, stroke: (black, 0.12)))
        add("Basiques", "Ombre douce", S(font: "Avenir Next", size: 0.08, shadow: (c(0, 0, 0, 0.8), 0.4, 0.02)))
        add("Basiques", "Fin et élégant", S(font: "Avenir Next", size: 0.07, bold: false, spacing: 0.25, sample: "ÉLÉGANT"))
        add("Basiques", "Majuscules espacées", S(font: "Futura", size: 0.065, spacing: 0.4, sample: "ESPACÉ"))
        add("Basiques", "Machine à écrire", S(font: "American Typewriter", size: 0.065, bold: false))
        add("Basiques", "Code", S(font: "Menlo", size: 0.055, color: lime, bold: false, background: (c(0.05, 0.05, 0.08, 0.9), 0.3, 0.1)))
        add("Basiques", "Citation", S(font: "Georgia", size: 0.06, bold: false, italic: true, sample: "« Citation »"))

        // Réseaux sociaux
        add("Réseaux sociaux", "Impact jaune", S(font: "Impact", size: 0.11, color: yellow, bold: false, stroke: (black, 0.12)))
        add("Réseaux sociaux", "Impact blanc", S(font: "Impact", size: 0.11, bold: false, stroke: (black, 0.12)))
        add("Réseaux sociaux", "Bulle blanche", S(size: 0.06, color: black, background: (white, 0.35, 0.5)))
        add("Réseaux sociaux", "Bulle noire", S(size: 0.06, background: (black, 0.35, 0.5)))
        add("Réseaux sociaux", "Surligné jaune", S(size: 0.065, color: black, background: (yellow, 0.25, 0.15)))
        add("Réseaux sociaux", "Surligné rose", S(size: 0.065, background: (pink, 0.25, 0.15)))
        add("Réseaux sociaux", "Étiquette rouge", S(font: "Futura", size: 0.06, background: (red, 0.3, 0.05), sample: "NOUVEAU"))
        add("Réseaux sociaux", "Gros chiffres", S(font: "Futura", size: 0.16, color: yellow, stroke: (black, 0.08), sample: "1 000"))
        add("Réseaux sociaux", "Sous-titre réseaux", S(size: 0.06, stroke: (black, 0.15), shadow: (c(0, 0, 0, 0.6), 0.1, 0.03), sample: "Sous-titre"))
        add("Réseaux sociaux", "Question", S(font: "Avenir Next", size: 0.06, color: black, background: (white, 0.4, 0.3), sample: "Votre avis ?"))

        // Néon et lumière
        add("Néon", "Néon rose", S(font: "Avenir Next", size: 0.09, color: c(1, 0.8, 0.95), shadow: (pink, 0.6, 0), sample: "Néon"))
        add("Néon", "Néon bleu", S(font: "Avenir Next", size: 0.09, color: c(0.85, 1, 1), shadow: (cyan, 0.6, 0), sample: "Néon"))
        add("Néon", "Néon vert", S(font: "Avenir Next", size: 0.09, color: c(0.9, 1, 0.85), shadow: (lime, 0.6, 0), sample: "Néon"))
        add("Néon", "Néon violet", S(font: "Futura", size: 0.09, color: c(0.92, 0.85, 1), shadow: (violet, 0.6, 0), sample: "Néon"))
        add("Néon", "Néon orange", S(font: "Futura", size: 0.09, color: c(1, 0.9, 0.8), shadow: (orange, 0.6, 0), sample: "Néon"))
        add("Néon", "Lueur dorée", S(font: "Didot", size: 0.09, color: c(1, 0.9, 0.6), shadow: (c(1, 0.7, 0.2), 0.5, 0), sample: "Doré"))
        add("Néon", "Contour lumineux", S(size: 0.09, color: c(0, 0, 0, 0.2), stroke: (cyan, 0.08), shadow: (cyan, 0.4, 0), sample: "Lumière"))
        add("Néon", "Arcade", S(font: "Menlo", size: 0.08, color: yellow, shadow: (red, 0.2, 0.06), sample: "ARCADE"))

        // Couleurs
        add("Couleurs", "Rouge vif", S(font: "Futura", size: 0.09, color: red, stroke: (white, 0.08)))
        add("Couleurs", "Bleu électrique", S(font: "Futura", size: 0.09, color: blue, stroke: (white, 0.08)))
        add("Couleurs", "Orange", S(size: 0.09, color: orange, shadow: (c(0, 0, 0, 0.6), 0.1, 0.04)))
        add("Couleurs", "Cyan", S(size: 0.09, color: cyan, stroke: (black, 0.08)))
        add("Couleurs", "Lime", S(size: 0.09, color: lime, stroke: (black, 0.08)))
        add("Couleurs", "Violet", S(font: "Avenir Next", size: 0.09, color: violet, stroke: (white, 0.06)))
        add("Couleurs", "Pastel", S(font: "Avenir Next", size: 0.08, color: c(1, 0.8, 0.85), stroke: (c(0.5, 0.35, 0.55), 0.06)))
        add("Couleurs", "Noir sur blanc", S(font: "Helvetica Neue", size: 0.08, color: black, background: (white, 0.2, 0)))

        // Élégant
        add("Élégant", "Didot", S(font: "Didot", size: 0.1, bold: false, sample: "Élégance"))
        add("Élégant", "Didot italique", S(font: "Didot", size: 0.09, bold: false, italic: true, sample: "Élégance"))
        add("Élégant", "Baskerville", S(font: "Baskerville", size: 0.08, bold: false, shadow: (c(0, 0, 0, 0.5), 0.2, 0.02)))
        add("Élégant", "Calligraphie", S(font: "Snell Roundhand", size: 0.1, bold: false, sample: "Merci"))
        add("Élégant", "Optima", S(font: "Optima", size: 0.08, bold: false, spacing: 0.15))
        add("Élégant", "Palatino doré", S(font: "Palatino", size: 0.08, color: c(0.95, 0.8, 0.45), bold: false))
        add("Élégant", "Copperplate", S(font: "Copperplate", size: 0.07, spacing: 0.1, sample: "PRESTIGE"))

        // Fun
        add("Fun", "Marqueur", S(font: "Marker Felt", size: 0.09, color: yellow, bold: false, stroke: (black, 0.06)))
        add("Fun", "Craie", S(font: "Chalkboard SE", size: 0.08, bold: false, background: (c(0.12, 0.25, 0.18, 0.95), 0.35, 0.05)))
        add("Fun", "Écrit à la main", S(font: "Bradley Hand", size: 0.09, color: c(0.15, 0.2, 0.55), bold: false, background: (c(1, 0.98, 0.85), 0.3, 0.05)))
        add("Fun", "Note autocollante", S(font: "Noteworthy", size: 0.07, color: black, bold: false, background: (yellow, 0.4, 0.05)))
        add("Fun", "Bande dessinée", S(font: "Chalkboard SE", size: 0.09, color: white, stroke: (black, 0.15), shadow: (black, 0, 0.06), sample: "BOUM !"))
        add("Fun", "Rétro 70", S(font: "American Typewriter", size: 0.09, color: orange, stroke: (c(0.45, 0.2, 0.05), 0.1), sample: "Rétro"))
        add("Fun", "Ombre portée", S(font: "Futura", size: 0.1, color: yellow, shadow: (c(0.9, 0.2, 0.4, 1), 0, 0.08), sample: "Pop"))
        return list
    }
}
