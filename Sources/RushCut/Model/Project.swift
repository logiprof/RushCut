import Foundation
import CoreGraphics

// MARK: - Décodage tolérant
//
// Chaque structure se décode avec des valeurs par défaut pour les champs absents :
// un projet enregistré par une version plus ancienne s'ouvre toujours.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) { return decoded }
        return fallback()
    }
}

// MARK: - Couleur

struct RGBA: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 1, g: 1, b: 1)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(cgColor: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let color = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? cgColor
        let c = color.components ?? [0, 0, 0, 1]
        if c.count >= 4 {
            self.init(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]), a: Double(c[3]))
        } else if c.count == 2 {
            self.init(r: Double(c[0]), g: Double(c[0]), b: Double(c[0]), a: Double(c[1]))
        } else {
            self.init(r: 0, g: 0, b: 0, a: 1)
        }
    }

    func with(alpha: Double) -> RGBA { var c = self; c.a = alpha; return c }
}

// MARK: - Réglages du projet

enum BackgroundMode: String, Codable, CaseIterable, Sendable {
    case color, blur
    var label: String { self == .color ? "Couleur" : "Flou de la vidéo" }
}

enum AspectPreset: String, CaseIterable, Identifiable, Sendable {
    case landscape16x9, portrait9x16, square1x1, portrait4x5, classic4x3, cinema21x9, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .landscape16x9: return "16:9"
        case .portrait9x16: return "9:16"
        case .square1x1: return "1:1"
        case .portrait4x5: return "4:5"
        case .classic4x3: return "4:3"
        case .cinema21x9: return "21:9"
        case .custom: return "Personnalisé"
        }
    }

    var usage: String {
        switch self {
        case .landscape16x9: return "YouTube, formation"
        case .portrait9x16: return "Reels, TikTok, Shorts"
        case .square1x1: return "Publication carrée"
        case .portrait4x5: return "Publication Instagram"
        case .classic4x3: return "Présentation"
        case .cinema21x9: return "Cinéma"
        case .custom: return "Taille libre"
        }
    }

    var size: (Int, Int) {
        switch self {
        case .landscape16x9: return (1920, 1080)
        case .portrait9x16: return (1080, 1920)
        case .square1x1: return (1080, 1080)
        case .portrait4x5: return (1080, 1350)
        case .classic4x3: return (1440, 1080)
        case .cinema21x9: return (2560, 1080)
        case .custom: return (1920, 1080)
        }
    }
}

struct ProjectSettings: Codable, Hashable, Sendable {
    var width: Int = 1920
    var height: Int = 1080
    var frameRate: Int = 30
    var backgroundColor: RGBA = .black
    var backgroundMode: BackgroundMode = .color

    var canvasSize: CGSize { CGSize(width: width, height: height) }

    var formatLabel: String {
        for preset in AspectPreset.allCases where preset != .custom {
            let (w, h) = preset.size
            if w * height == h * width { return preset.label }
        }
        return "\(width)×\(height)"
    }

    static let supportedFrameRates = [24, 25, 30, 50, 60]
}

extension ProjectSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = max(16, c.value(.width, 1920))
        height = max(16, c.value(.height, 1080))
        let rate = c.value(.frameRate, 30)
        frameRate = ProjectSettings.supportedFrameRates.contains(rate) ? rate : 30
        backgroundColor = c.value(.backgroundColor, .black)
        backgroundMode = c.value(.backgroundMode, .color)
    }
}

// MARK: - Médias

enum MediaKind: String, Codable, Sendable {
    case video, audio, image

    var label: String {
        switch self {
        case .video: return "Vidéo"
        case .audio: return "Audio"
        case .image: return "Image"
        }
    }
}

struct MediaRef: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    /// Chemin absolu du fichier source (jamais modifié par l'application).
    var path: String = ""
    /// Signet permettant de retrouver le fichier s'il a été déplacé.
    var bookmark: Data? = nil
    var kind: MediaKind = .video
    var duration: RTime = .zero
    /// Taille affichée (rotation déjà appliquée).
    var width: Int = 0
    var height: Int = 0
    var frameRate: Double = 0
    var hasAudio: Bool = false
    var isAnimated: Bool = false
    var proxyPath: String? = nil
    var importedAt: Date = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var pixelSize: CGSize { CGSize(width: max(width, 1), height: max(height, 1)) }
    var hasVideo: Bool { kind == .video || kind == .image }
}

extension MediaRef {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "")
        path = c.value(.path, "")
        bookmark = c.value(.bookmark, nil)
        kind = c.value(.kind, .video)
        duration = c.value(.duration, .zero)
        width = c.value(.width, 0)
        height = c.value(.height, 0)
        frameRate = c.value(.frameRate, 0)
        hasAudio = c.value(.hasAudio, false)
        isAnimated = c.value(.isAnimated, false)
        proxyPath = c.value(.proxyPath, nil)
        importedAt = c.value(.importedAt, Date())
    }
}

// MARK: - Pistes

enum TrackKind: String, Codable, Sendable {
    case video, audio, text, sticker, effect

    var isVisual: Bool { self != .audio }
}

struct Track: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: TrackKind = .video
    var clips: [Clip] = []
    var isMuted: Bool = false
    var isLocked: Bool = false
    var isHidden: Bool = false
    /// Piste principale magnétique (une seule par projet).
    var isMain: Bool = false
}

extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        kind = c.value(.kind, .video)
        clips = c.value(.clips, [])
        isMuted = c.value(.isMuted, false)
        isLocked = c.value(.isLocked, false)
        isHidden = c.value(.isHidden, false)
        isMain = c.value(.isMain, false)
    }
}

// MARK: - Clips

struct Transform: Codable, Hashable, Sendable {
    /// Décalage du centre, en fraction de la largeur / hauteur du cadre (0 = centré, y vers le bas).
    var positionX: Double = 0
    var positionY: Double = 0
    var scale: Double = 1
    /// Degrés, sens horaire.
    var rotation: Double = 0
    var flipH: Bool = false
    var flipV: Bool = false
}

extension Transform {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positionX = c.value(.positionX, 0)
        positionY = c.value(.positionY, 0)
        scale = c.value(.scale, 1)
        rotation = c.value(.rotation, 0)
        flipH = c.value(.flipH, false)
        flipV = c.value(.flipV, false)
    }
}

/// Recadrage : part retirée de chaque bord, en fraction de la taille source.
struct CropRect: Codable, Hashable, Sendable {
    var left: Double = 0
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0

    var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

extension CropRect {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = c.value(.left, 0)
        top = c.value(.top, 0)
        right = c.value(.right, 0)
        bottom = c.value(.bottom, 0)
    }
}

enum FitMode: String, Codable, CaseIterable, Sendable {
    case fit, fill, stretch, none

    var label: String {
        switch self {
        case .fit: return "Ajuster"
        case .fill: return "Remplir"
        case .stretch: return "Étirer"
        case .none: return "Taille réelle"
        }
    }
}

enum BlendMode: String, Codable, Sendable {
    case normal, multiply, screen, overlay, softLight, darken, lighten, difference
}

struct AudioSettings: Codable, Hashable, Sendable {
    /// Volume en décibels (0 = inchangé, −60 = silence).
    var volumeDB: Double = 0
    var fadeIn: RTime = .zero
    var fadeOut: RTime = .zero
    /// Vrai quand le son a été détaché vers une piste audio.
    var isMuted: Bool = false
    /// Réduction de bruit (0 = désactivée, 1 = forte).
    var denoise: Double = 0
    /// Atténuation automatique (dB, négatif) quand un autre son joue en même temps (0 = désactivée).
    var duckDB: Double = 0
    /// Effet de voix (lot V2), identifiant dans le catalogue.
    var voiceEffect: String? = nil

    static let silenceDB: Double = -60

    var linearGain: Float {
        if isMuted || volumeDB <= AudioSettings.silenceDB { return 0 }
        return Float(min(1, pow(10, volumeDB / 20)))
    }

    /// Gain au-delà de 0 dB (appliqué par le traitement audio).
    static func extraGain(db: Double) -> Float {
        db > 0 ? Float(pow(10, min(20, db) / 20)) : 1
    }
}

extension AudioSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeDB = c.value(.volumeDB, 0)
        fadeIn = c.value(.fadeIn, .zero)
        fadeOut = c.value(.fadeOut, .zero)
        isMuted = c.value(.isMuted, false)
        denoise = c.value(.denoise, 0)
        duckDB = c.value(.duckDB, 0)
        voiceEffect = c.value(.voiceEffect, nil)
    }
}

struct SpeedPoint: Codable, Hashable, Sendable {
    /// Position dans le clip (0–1) et vitesse à cet endroit.
    var position: Double
    var rate: Double
}

struct SpeedCurve: Codable, Hashable, Sendable {
    /// Vitesse constante (0,1× à 100×).
    var rate: Double = 1
    /// Conserver la hauteur du son quand la vitesse change.
    var preservePitch: Bool = true
    /// Courbe de vitesse (lot V2) ; vide = vitesse constante.
    var curve: [SpeedPoint] = []
    var curveName: String? = nil
}

extension SpeedCurve {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rate = c.value(.rate, 1)
        preservePitch = c.value(.preservePitch, true)
        curve = c.value(.curve, [])
        curveName = c.value(.curveName, nil)
    }
}

struct EffectInstance: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Identifiant dans le catalogue d'effets.
    var type: String = ""
    var params: [String: Double] = [:]
    /// Intensité 0–1.
    var intensity: Double = 1
}

extension EffectInstance {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        type = c.value(.type, "")
        params = c.value(.params, [:])
        intensity = c.value(.intensity, 1)
    }
}

struct Transition: Codable, Hashable, Sendable {
    /// Identifiant dans le catalogue de transitions.
    var type: String = "fondu"
    var duration: RTime = RTime(seconds: 0.5)
}

enum Interpolation: String, Codable, CaseIterable, Sendable {
    case lineaire, douce, entree, sortie, maintien

    var label: String {
        switch self {
        case .lineaire: return "Linéaire"
        case .douce: return "Douce"
        case .entree: return "Entrée douce"
        case .sortie: return "Sortie douce"
        case .maintien: return "Maintien"
        }
    }
}

struct Keyframe: Codable, Hashable, Sendable {
    /// Temps depuis le début du clip.
    var time: RTime = .zero
    var value: Double = 0
    var interpolation: Interpolation = .douce
}

extension Keyframe {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = c.value(.time, .zero)
        value = c.value(.value, 0)
        interpolation = c.value(.interpolation, .douce)
    }
}

enum MaskShape: String, Codable, CaseIterable, Sendable {
    case lineaire, miroir, cercle, rectangle

    var label: String {
        switch self {
        case .lineaire: return "Linéaire"
        case .miroir: return "Miroir"
        case .cercle: return "Cercle"
        case .rectangle: return "Rectangle"
        }
    }
}

/// Masque, en fractions de la taille de la source (centre 0 = milieu).
struct Mask: Codable, Hashable, Sendable {
    var shape: MaskShape = .cercle
    var centerX: Double = 0
    var centerY: Double = 0
    var width: Double = 0.6
    var height: Double = 0.6
    var rotation: Double = 0
    var feather: Double = 0.05
    var cornerRadius: Double = 0.1
    var invert: Bool = false
}

extension Mask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Mask()
        shape = c.value(.shape, d.shape)
        centerX = c.value(.centerX, d.centerX)
        centerY = c.value(.centerY, d.centerY)
        width = c.value(.width, d.width)
        height = c.value(.height, d.height)
        rotation = c.value(.rotation, d.rotation)
        feather = c.value(.feather, d.feather)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        invert = c.value(.invert, d.invert)
    }
}

/// Réglages de couleur, chacun de −1 à 1 (0 = neutre), sauf netteté, vignettage et grain (0 à 1).
struct ColorAdjust: Codable, Hashable, Sendable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0
    var grain: Double = 0

    var isNeutral: Bool { self == ColorAdjust() }
}

extension ColorAdjust {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = c.value(.exposure, 0)
        brightness = c.value(.brightness, 0)
        contrast = c.value(.contrast, 0)
        saturation = c.value(.saturation, 0)
        vibrance = c.value(.vibrance, 0)
        temperature = c.value(.temperature, 0)
        tint = c.value(.tint, 0)
        highlights = c.value(.highlights, 0)
        shadows = c.value(.shadows, 0)
        sharpness = c.value(.sharpness, 0)
        vignette = c.value(.vignette, 0)
        grain = c.value(.grain, 0)
    }
}

struct FilterRef: Codable, Hashable, Sendable {
    var id: String
    var intensity: Double = 1
}

struct ChromaKey: Codable, Hashable, Sendable {
    var color: RGBA = RGBA(r: 0, g: 0.8, b: 0.2)
    /// Écart de teinte accepté (0–1).
    var tolerance: Double = 0.25
    var softness: Double = 0.1
    /// Suppression du débordement de couleur (0–1).
    var spill: Double = 0.5
}

/// Habillage d'un calque (incrustation) : coins arrondis, bordure, ombre.
struct LayerStyle: Codable, Hashable, Sendable {
    /// Rayon des coins en fraction du plus petit côté.
    var cornerRadius: Double = 0
    /// Épaisseur de la bordure en fraction du plus petit côté du cadre.
    var borderWidth: Double = 0
    var borderColor: RGBA = .white
    /// Ombre portée (0–1).
    var shadow: Double = 0

    var isPlain: Bool { cornerRadius == 0 && borderWidth == 0 && shadow == 0 }
}

/// Animation d'entrée, de sortie ou en boucle (identifiant du catalogue + durée).
struct ClipAnimation: Codable, Hashable, Sendable {
    var id: String
    var duration: RTime = RTime(seconds: 0.6)
}

/// Mot d'un sous-titre, avec son instant de prononciation (depuis le début du clip).
struct WordTiming: Codable, Hashable, Sendable {
    var text: String
    var start: RTime
    var end: RTime
}

enum TextAlignmentMode: String, Codable, CaseIterable, Sendable {
    case left, center, right

    var label: String {
        switch self {
        case .left: return "Gauche"
        case .center: return "Centre"
        case .right: return "Droite"
        }
    }
}

struct TextContent: Codable, Hashable, Sendable {
    var string: String = "Votre texte"
    var fontName: String = "Helvetica Neue"
    /// Taille de la police en fraction de la hauteur du cadre.
    var fontSize: Double = 0.07
    var color: RGBA = .white
    var bold: Bool = true
    var italic: Bool = false
    var alignment: TextAlignmentMode = .center
    /// Interlettrage en fraction de la taille de police.
    var letterSpacing: Double = 0
    /// Interligne supplémentaire en fraction de la taille de police.
    var lineSpacing: Double = 0
    var strokeEnabled: Bool = false
    var strokeColor: RGBA = .black
    /// Épaisseur du contour en fraction de la taille de police.
    var strokeWidth: Double = 0.08
    var shadowEnabled: Bool = false
    var shadowColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.7)
    var shadowBlur: Double = 0.15
    var shadowOffset: Double = 0.05
    var backgroundEnabled: Bool = false
    var backgroundColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.7)
    var backgroundPadding: Double = 0.3
    var backgroundCornerRadius: Double = 0.2
    /// Animation du texte (machine à écrire, mot par mot, karaoké…), identifiant du catalogue.
    var animation: String? = nil
    /// Durée d'apparition progressive, en secondes.
    var animationDuration: Double = 1
    var highlightColor: RGBA = RGBA(r: 1, g: 0.85, b: 0.1)
    /// Mots minutés (sous-titres automatiques).
    var words: [WordTiming] = []
    /// Vrai pour les sous-titres (piste et liste dédiées).
    var isSubtitle: Bool = false
}

extension TextContent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextContent()
        string = c.value(.string, d.string)
        fontName = c.value(.fontName, d.fontName)
        fontSize = c.value(.fontSize, d.fontSize)
        color = c.value(.color, d.color)
        bold = c.value(.bold, d.bold)
        italic = c.value(.italic, d.italic)
        alignment = c.value(.alignment, d.alignment)
        letterSpacing = c.value(.letterSpacing, d.letterSpacing)
        lineSpacing = c.value(.lineSpacing, d.lineSpacing)
        strokeEnabled = c.value(.strokeEnabled, d.strokeEnabled)
        strokeColor = c.value(.strokeColor, d.strokeColor)
        strokeWidth = c.value(.strokeWidth, d.strokeWidth)
        shadowEnabled = c.value(.shadowEnabled, d.shadowEnabled)
        shadowColor = c.value(.shadowColor, d.shadowColor)
        shadowBlur = c.value(.shadowBlur, d.shadowBlur)
        shadowOffset = c.value(.shadowOffset, d.shadowOffset)
        backgroundEnabled = c.value(.backgroundEnabled, d.backgroundEnabled)
        backgroundColor = c.value(.backgroundColor, d.backgroundColor)
        backgroundPadding = c.value(.backgroundPadding, d.backgroundPadding)
        backgroundCornerRadius = c.value(.backgroundCornerRadius, d.backgroundCornerRadius)
        animation = c.value(.animation, nil)
        animationDuration = c.value(.animationDuration, d.animationDuration)
        highlightColor = c.value(.highlightColor, d.highlightColor)
        words = c.value(.words, [])
        isSubtitle = c.value(.isSubtitle, false)
    }
}

struct Clip: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// nil pour un texte.
    var mediaID: UUID? = nil
    var name: String = ""
    /// Position dans la timeline.
    var start: RTime = .zero
    /// Point d'entrée dans le média source.
    var sourceIn: RTime = .zero
    var duration: RTime = RTime(seconds: 5)
    var speed: SpeedCurve = SpeedCurve()
    var transform: Transform = Transform()
    var opacity: Double = 1
    var blendMode: BlendMode = .normal
    var crop: CropRect = CropRect()
    var fit: FitMode = .fit
    var audio: AudioSettings = AudioSettings()
    var effects: [EffectInstance] = []
    var transitionIn: Transition? = nil
    var keyframes: [String: [Keyframe]] = [:]
    var text: TextContent? = nil
    var mask: Mask? = nil
    var linkedClipIDs: [UUID] = []
    var adjust: ColorAdjust = ColorAdjust()
    var filter: FilterRef? = nil
    var chroma: ChromaKey? = nil
    var style: LayerStyle = LayerStyle()
    var animIn: ClipAnimation? = nil
    var animOut: ClipAnimation? = nil
    var animLoop: ClipAnimation? = nil
    /// Autocollant dessiné (identifiant du catalogue).
    var sticker: String? = nil
    var stickerColor: RGBA = RGBA(r: 1, g: 0.85, b: 0.1)
    /// Détourage automatique (lot V2).
    var cutout: CutoutMode? = nil
    /// Retouche du visage (lot V2).
    var retouch: Retouch = Retouch()
    /// Groupe de clips qui se déplacent ensemble (lot V2).
    var groupID: UUID? = nil
    /// Clip composé : projet d'origine conservé pour pouvoir le décomposer (JSON).
    var compoundSource: Data? = nil

    var end: RTime { start + duration }
    var isSticker: Bool { sticker != nil }
    /// Clip sans média ni texte ni autocollant : effet appliqué aux pistes du dessous.
    var isEffectOnly: Bool { mediaID == nil && text == nil && sticker == nil }
    var isText: Bool { text != nil }

    func contains(_ time: RTime) -> Bool { start <= time && time < end }
}

extension Clip {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        mediaID = c.value(.mediaID, nil)
        name = c.value(.name, "")
        start = c.value(.start, .zero)
        sourceIn = c.value(.sourceIn, .zero)
        duration = c.value(.duration, RTime(seconds: 5))
        speed = c.value(.speed, SpeedCurve())
        transform = c.value(.transform, Transform())
        opacity = c.value(.opacity, 1)
        blendMode = c.value(.blendMode, .normal)
        crop = c.value(.crop, CropRect())
        fit = c.value(.fit, .fit)
        audio = c.value(.audio, AudioSettings())
        effects = c.value(.effects, [])
        transitionIn = c.value(.transitionIn, nil)
        keyframes = c.value(.keyframes, [:])
        text = c.value(.text, nil)
        mask = c.value(.mask, nil)
        linkedClipIDs = c.value(.linkedClipIDs, [])
        adjust = c.value(.adjust, ColorAdjust())
        filter = c.value(.filter, nil)
        chroma = c.value(.chroma, nil)
        style = c.value(.style, LayerStyle())
        animIn = c.value(.animIn, nil)
        animOut = c.value(.animOut, nil)
        animLoop = c.value(.animLoop, nil)
        sticker = c.value(.sticker, nil)
        stickerColor = c.value(.stickerColor, RGBA(r: 1, g: 0.85, b: 0.1))
        cutout = c.value(.cutout, nil)
        retouch = c.value(.retouch, Retouch())
        groupID = c.value(.groupID, nil)
        compoundSource = c.value(.compoundSource, nil)
    }
}

enum CutoutMode: String, Codable, CaseIterable, Sendable {
    case personne, sujet
    var label: String { self == .personne ? "Personnes" : "Sujet principal" }
}

struct Retouch: Codable, Hashable, Sendable {
    /// Lissage de la peau (0–1).
    var smooth: Double = 0
    /// Éclat du visage (0–1).
    var brighten: Double = 0
    var isOff: Bool { smooth == 0 && brighten == 0 }
}

extension Retouch {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smooth = c.value(.smooth, 0)
        brighten = c.value(.brighten, 0)
    }
}

// MARK: - Marqueurs

struct Marker: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: RTime = .zero
    var name: String = ""
    var color: RGBA = RGBA(r: 1, g: 0.75, b: 0.1)
}

extension Marker {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        time = c.value(.time, .zero)
        name = c.value(.name, "")
        color = c.value(.color, RGBA(r: 1, g: 0.75, b: 0.1))
    }
}

// MARK: - Projet

struct Project: Codable, Hashable, Identifiable, Sendable {
    static let currentVersion = 1

    var version: Int = Project.currentVersion
    var id: UUID = UUID()
    var name: String = "Sans titre"
    var settings: ProjectSettings = ProjectSettings()
    var media: [MediaRef] = []
    var tracks: [Track] = [Track(kind: .video, isMain: true)]
    var markers: [Marker] = []
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, 0)
        id = c.value(.id, UUID())
        name = c.value(.name, "Sans titre")
        settings = c.value(.settings, ProjectSettings())
        media = c.value(.media, [])
        tracks = c.value(.tracks, [Track(kind: .video, isMain: true)])
        markers = c.value(.markers, [])
        createdAt = c.value(.createdAt, Date())
        modifiedAt = c.value(.modifiedAt, Date())
    }
}
