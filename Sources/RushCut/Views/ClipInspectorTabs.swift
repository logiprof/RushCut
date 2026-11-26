import SwiftUI
import AppKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case texte, base, animation, vitesse, ajuster, masque, effets, incrustation, audio
    var id: String { rawValue }

    var label: String {
        switch self {
        case .texte: return "Texte"
        case .base: return "Image"
        case .animation: return "Animation"
        case .vitesse: return "Vitesse"
        case .ajuster: return "Ajuster"
        case .masque: return "Masque"
        case .effets: return "Effets"
        case .incrustation: return "Incrustation"
        case .audio: return "Audio"
        }
    }

    var icon: String {
        switch self {
        case .texte: return "textformat"
        case .base: return "crop.rotate"
        case .animation: return "wand.and.rays"
        case .vitesse: return "gauge.with.dots.needle.67percent"
        case .ajuster: return "slider.horizontal.3"
        case .masque: return "circle.lefthalf.filled"
        case .effets: return "sparkles"
        case .incrustation: return "square.on.square"
        case .audio: return "speaker.wave.2"
        }
    }
}

struct InspectorTabBar: View {
    let tabs: [InspectorTab]
    let selection: InspectorTab
    let onSelect: (InspectorTab) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 4)], spacing: 4) {
            ForEach(tabs) { tab in
                Button { onSelect(tab) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 13))
                        Text(tab.label).font(.system(size: 9.5)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selection == tab ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.03)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension BlendMode: CaseIterable {
    static var allCases: [BlendMode] { [.normal, .multiply, .screen, .overlay, .softLight, .darken, .lighten, .difference] }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Produit"
        case .screen: return "Superposition claire (écran)"
        case .overlay: return "Incrustation"
        case .softLight: return "Lumière tamisée"
        case .darken: return "Assombrir"
        case .lighten: return "Éclaircir"
        case .difference: return "Différence"
        }
    }
}

// MARK: - Curseur avec image clé

/// Curseur d'un paramètre animable, avec le losange qui pose ou retire l'image clé à la tête de lecture.
struct KeyframeSlider: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: PlaybackController
    let clip: Clip
    let prop: KeyProp
    var title: String? = nil
    var factor: Double = 1
    let range: ClosedRange<Double>
    var unit = ""
    var fractionDigits = 0

    var body: some View {
        let local = model.localTime(in: clip)
        let value = clip.value(prop, at: local ?? .zero) * factor
        let onKey = local.flatMap { clip.keyframeIndex(prop, near: $0, fps: model.fps) } != nil
        let has = clip.hasKeyframes(prop)
        HStack(alignment: .center, spacing: 6) {
            SliderField(title: title ?? prop.label, value: value, range: range, unit: unit, fractionDigits: fractionDigits) { v in
                model.setKeyframed(prop, v / factor, clipID: clip.id, name: title ?? prop.label, coalesce: "kf-\(prop.rawValue)")
            }
            Button { model.toggleKeyframe(prop, clipID: clip.id) } label: {
                Image(systemName: onKey ? "diamond.fill" : "diamond")
                    .font(.system(size: 12))
                    .foregroundStyle(onKey ? Color.accentColor : (has ? Color.primary : Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(local == nil)
            .help(onKey ? "Retirer l'image clé" : "Ajouter une image clé à la tête de lecture")
        }
    }
}

/// Navigation entre images clés et choix de l'interpolation de celle sous la tête de lecture.
struct KeyframeNavigator: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: PlaybackController
    let clip: Clip
    let props: [KeyProp]

    var body: some View {
        let local = model.localTime(in: clip)
        let current = props.first { p in local.flatMap { clip.keyframeIndex(p, near: $0, fps: model.fps) } != nil }
        if props.contains(where: { clip.hasKeyframes($0) }) {
            HStack(spacing: 8) {
                Button { model.jumpToKeyframe(clipID: clip.id, forward: false) } label: { Image(systemName: "chevron.left") }
                    .help("Image clé précédente")
                Image(systemName: "diamond.fill").foregroundStyle(Color.accentColor).font(.caption)
                Button { model.jumpToKeyframe(clipID: clip.id, forward: true) } label: { Image(systemName: "chevron.right") }
                    .help("Image clé suivante")
                Spacer()
                if let current, let local, let i = clip.keyframeIndex(current, near: local, fps: model.fps) {
                    let mode = clip.keyframes[current.rawValue]?[i].interpolation ?? .douce
                    Picker("", selection: Binding(get: { mode }, set: { v in props.forEach { model.setInterpolation($0, v, clipID: clip.id) } })) {
                        ForEach(Interpolation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .help("Courbe entre cette image clé et la suivante")
                }
            }
            .controlSize(.small)
            Button("Effacer toutes les images clés") {
                model.updateClip(clip.id, "Effacer les images clés") { c in props.forEach { c.keyframes[$0.rawValue] = nil } }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Animation

struct AnimationTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    @State private var kind: AnimationKind = .entree

    private func current(_ c: Clip) -> ClipAnimation? {
        switch kind {
        case .entree: return c.animIn
        case .sortie: return c.animOut
        case .boucle: return c.animLoop
        }
    }

    private func set(_ value: ClipAnimation?) {
        let k = kind
        model.updateClip(clip.id, "Animation") { c in
            switch k {
            case .entree: c.animIn = value
            case .sortie: c.animOut = value
            case .boucle: c.animLoop = value
            }
        }
    }

    var body: some View {
        let selected = current(clip)
        InspectorSection(title: "Animation du clip") {
            Picker("", selection: $kind) {
                ForEach(AnimationKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                CatalogTile(key: "anim-aucune", title: "Aucune", isSelected: selected == nil,
                            make: { _, _, base in CatalogThumbnails.applying(AnimState(scale: 0.6), to: base) },
                            action: { set(nil) })
                ForEach(AnimationCatalog.list(kind)) { def in
                    CatalogTile(key: "anim-\(def.id)", title: def.name, isSelected: selected?.id == def.id, animatedFrames: 14,
                                make: { f, n, base in CatalogThumbnails.animation(def, frame: f, frames: n, base: base) },
                                action: {
                                    let d = selected?.duration ?? RTime(seconds: kind == .boucle ? 1.2 : 0.6)
                                    set(ClipAnimation(id: def.id, duration: d))
                                })
                }
            }
            if let selected {
                let maxD = max(0.2, min(kind == .boucle ? 5 : clip.duration.seconds, 10))
                SliderField(title: kind == .boucle ? "Durée d'un cycle" : "Durée", value: selected.duration.seconds,
                            range: 0.1...maxD, unit: "s", fractionDigits: 1) { v in
                    var a = selected
                    a.duration = RTime(seconds: v).snapped(fps: model.fps)
                    set(a)
                }
            }
        }
        if let text = clip.text {
            InspectorSection(title: "Animation du texte") {
                Picker("Animation", selection: Binding(get: { text.animation ?? "" }, set: { v in
                    model.updateClip(clip.id, "Animation du texte") { $0.text?.animation = v.isEmpty ? nil : v }
                })) {
                    Text("Aucune").tag("")
                    ForEach(TextAnimationCatalog.all) { Text($0.name).tag($0.id) }
                }
                if text.animation != nil {
                    SliderField(title: "Durée", value: text.animationDuration, range: 0.2...max(0.3, clip.duration.seconds),
                                unit: "s", fractionDigits: 1) { v in
                        model.updateClip(clip.id, "Durée de l'animation", coalesce: "texteAnim") { $0.text?.animationDuration = v }
                    }
                    if text.animation?.hasPrefix("texte-karaoke") == true {
                        ColorPicker("Couleur du mot prononcé", selection: Binding(get: { text.highlightColor.cgColor }, set: { c in
                            model.updateClip(clip.id, "Couleur karaoké", coalesce: "karaoke") { $0.text?.highlightColor = RGBA(cgColor: c) }
                        }))
                    }
                }
            }
        }
    }
}

// MARK: - Vitesse

struct SpeedTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    var body: some View {
        let rate = clip.speed.rate
        InspectorSection(title: "Vitesse constante") {
            HStack {
                Text("Vitesse")
                Spacer()
                Text(String(format: "×%.2f", rate)).monospacedDigit().foregroundStyle(Color.accentColor)
            }
            Slider(value: Binding(get: { log10(rate) }, set: { model.setSpeed(clip.id, rate: (pow(10, $0) * 100).rounded() / 100) }), in: -1...2)
                .controlSize(.small)
            HStack {
                ForEach([0.25, 0.5, 1, 2, 4, 10], id: \.self) { r in
                    Button(r < 1 ? "×\(r)" : "×\(Int(r))") { model.setSpeed(clip.id, rate: r) }
                        .controlSize(.small)
                }
            }
            LabeledContent("Durée obtenue", value: clip.duration.timecode(fps: model.fps))
            Toggle("Conserver la hauteur du son", isOn: Binding(get: { clip.speed.preservePitch }, set: { v in
                model.updateClip(clip.id, "Hauteur du son") { $0.speed.preservePitch = v }
            }))
            .help("Désactivé, le son devient plus aigu en accéléré et plus grave au ralenti.")
            Text("De ×0,1 (ralenti) à ×100 (accéléré). Les images clés suivent la nouvelle durée.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ajustements

struct AdjustTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    private func slider(_ title: String, _ kp: WritableKeyPath<ColorAdjust, Double>, _ range: ClosedRange<Double> = -100...100) -> some View {
        SliderField(title: title, value: clip.adjust[keyPath: kp] * 100, range: range) { v in
            model.updateClip(clip.id, title, coalesce: "adj-\(title)") { $0.adjust[keyPath: kp] = v / 100 }
        }
    }

    var body: some View {
        InspectorSection(title: "Ajustements") {
            HStack {
                if clip.mediaID != nil {
                    Button { model.autoEnhance(clip.id) } label: { Label("Amélioration auto", systemImage: "wand.and.stars") }
                        .help("Analyse l'image sous la tête de lecture et corrige exposition, couleurs et contraste.")
                }
                Spacer()
                Button("Réinitialiser") { model.updateClip(clip.id, "Réinitialiser les ajustements") { $0.adjust = ColorAdjust() } }
                    .disabled(clip.adjust.isNeutral)
            }
            .controlSize(.small)
            Group {
                slider("Exposition", \.exposure)
                slider("Luminosité", \.brightness)
                slider("Contraste", \.contrast)
                slider("Hautes lumières", \.highlights)
                slider("Ombres", \.shadows)
            }
            Group {
                slider("Saturation", \.saturation)
                slider("Vibrance", \.vibrance)
                slider("Température", \.temperature)
                slider("Teinte", \.tint)
            }
            Group {
                slider("Netteté", \.sharpness, 0...100)
                slider("Vignette", \.vignette, 0...100)
                slider("Grain", \.grain, 0...100)
            }
        }
        FilterSection(model: model, clip: clip)
    }
}

struct FilterSection: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    var body: some View {
        InspectorSection(title: "Filtre") {
            if let filter = clip.filter {
                HStack {
                    Text(FilterCatalog.byID[filter.id]?.name ?? filter.id).font(.body.weight(.medium))
                    Spacer()
                    Button("Retirer") { model.updateClip(clip.id, "Retirer le filtre") { $0.filter = nil } }
                        .controlSize(.small)
                }
                SliderField(title: "Intensité", value: filter.intensity * 100, range: 0...100, unit: "%") { v in
                    model.updateClip(clip.id, "Intensité du filtre", coalesce: "filtreI") { $0.filter?.intensity = v / 100 }
                }
            } else {
                Text("Aucun filtre.").foregroundStyle(.secondary)
            }
            Button("Parcourir les filtres…") { model.libraryTab = .filters }
                .controlSize(.small)
        }
    }
}

// MARK: - Masque

struct MaskTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    private func update(_ name: String, _ body: @escaping (inout Mask) -> Void) {
        model.updateClip(clip.id, name, coalesce: "masque-\(name)") { c in
            var m = c.mask ?? Mask()
            body(&m)
            c.mask = m
        }
    }

    var body: some View {
        InspectorSection(title: "Masque") {
            Picker("Forme", selection: Binding(get: { clip.mask?.shape.rawValue ?? "" }, set: { v in
                model.updateClip(clip.id, "Masque") { c in
                    if let shape = MaskShape(rawValue: v) {
                        var m = c.mask ?? Mask()
                        m.shape = shape
                        c.mask = m
                    } else {
                        c.mask = nil
                    }
                }
            })) {
                Text("Aucun").tag("")
                ForEach(MaskShape.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if let m = clip.mask {
                SliderField(title: "Centre X", value: m.centerX * 100, range: -50...50, unit: "%") { v in update("Centre X") { $0.centerX = v / 100 } }
                SliderField(title: "Centre Y", value: m.centerY * 100, range: -50...50, unit: "%") { v in update("Centre Y") { $0.centerY = v / 100 } }
                if m.shape == .cercle || m.shape == .rectangle || m.shape == .miroir {
                    SliderField(title: m.shape == .miroir ? "Épaisseur" : "Largeur", value: m.width * 100, range: 1...200, unit: "%") { v in update("Largeur") { $0.width = v / 100 } }
                }
                if m.shape == .cercle || m.shape == .rectangle {
                    SliderField(title: "Hauteur", value: m.height * 100, range: 1...200, unit: "%") { v in update("Hauteur") { $0.height = v / 100 } }
                }
                SliderField(title: "Rotation", value: m.rotation, range: -180...180, unit: "°") { v in update("Rotation") { $0.rotation = v } }
                SliderField(title: "Contour progressif", value: m.feather * 100, range: 0...50, unit: "%") { v in update("Contour progressif") { $0.feather = v / 100 } }
                if m.shape == .rectangle {
                    SliderField(title: "Coins arrondis", value: m.cornerRadius * 100, range: 0...50, unit: "%") { v in update("Coins") { $0.cornerRadius = v / 100 } }
                }
                Toggle("Inverser", isOn: Binding(get: { m.invert }, set: { v in update("Inverser") { $0.invert = v } }))
            }
        }
    }
}

// MARK: - Effets

struct EffectsTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    var body: some View {
        InspectorSection(title: clip.isEffectOnly ? "Effets de la piste" : "Effets du clip") {
            if clip.effects.isEmpty {
                Text("Aucun effet.").foregroundStyle(.secondary)
            }
            ForEach(clip.effects) { effect in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text(EffectCatalog.byID[effect.type]?.name ?? effect.type).font(.body.weight(.medium))
                        Spacer()
                        Button { model.removeEffect(effect.id, from: clip.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .help("Retirer l'effet")
                    }
                    SliderField(title: "Intensité", value: effect.intensity * 100, range: 0...100, unit: "%") { v in
                        model.updateClip(clip.id, "Intensité de l'effet", coalesce: "effet-\(effect.id)") { c in
                            if let i = c.effects.firstIndex(where: { $0.id == effect.id }) { c.effects[i].intensity = v / 100 }
                        }
                    }
                }
                Divider()
            }
            Button("Ajouter un effet…") { model.libraryTab = .effects }
                .controlSize(.small)
        }
        if clip.isEffectOnly && clip.filter != nil {
            FilterSection(model: model, clip: clip)
        }
        if let mi = model.project.mainTrackIndex, let i = model.project.tracks[mi].clips.firstIndex(where: { $0.id == clip.id }), i > 0 {
            TransitionSection(model: model, clip: clip)
        }
    }
}

struct TransitionSection: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    var body: some View {
        InspectorSection(title: "Transition d'entrée") {
            Picker("Transition", selection: Binding(get: { clip.transitionIn?.type ?? "" }, set: { v in
                model.selection = [clip.id]
                model.useTransition(v.isEmpty ? nil : TransitionCatalog.byID[v])
            })) {
                Text("Aucune").tag("")
                ForEach(TransitionCatalog.all) { Text("\($0.category) · \($0.name)").tag($0.id) }
            }
            if let tr = clip.transitionIn {
                SliderField(title: "Durée", value: tr.duration.seconds, range: 0.1...3, unit: "s", fractionDigits: 1) { v in
                    model.setTransitionDuration(clip.id, seconds: v)
                }
                Button("Appliquer à tous les raccords") { model.useTransitionEverywhere(tr.type, duration: tr.duration) }
                    .controlSize(.small)
            }
            Button("Parcourir les transitions…") { model.libraryTab = .transitions }
                .controlSize(.small)
        }
    }
}

// MARK: - Incrustation

struct OverlayTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    var body: some View {
        InspectorSection(title: "Mode de fusion") {
            Picker("Fusion", selection: Binding(get: { clip.blendMode }, set: { v in model.updateClip(clip.id, "Mode de fusion") { $0.blendMode = v } })) {
                ForEach(BlendMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Le mode de fusion mélange ce calque avec ce qui est dessous.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if clip.mediaID != nil {
            InspectorSection(title: "Incrustation (fond vert)") {
                Toggle("Supprimer une couleur", isOn: Binding(get: { clip.chroma != nil }, set: { v in
                    model.updateClip(clip.id, "Incrustation") { $0.chroma = v ? ChromaKey() : nil }
                }))
                if let k = clip.chroma {
                    ColorPicker("Couleur à supprimer", selection: Binding(get: { k.color.cgColor }, set: { c in
                        model.updateClip(clip.id, "Couleur d'incrustation", coalesce: "chromaC") { $0.chroma?.color = RGBA(cgColor: c) }
                    }), supportsOpacity: false)
                    HStack {
                        Button("Vert") { model.updateClip(clip.id, "Couleur d'incrustation") { $0.chroma?.color = RGBA(r: 0, g: 0.8, b: 0.2) } }
                        Button("Bleu") { model.updateClip(clip.id, "Couleur d'incrustation") { $0.chroma?.color = RGBA(r: 0.05, g: 0.3, b: 0.95) } }
                    }
                    .controlSize(.small)
                    SliderField(title: "Tolérance", value: k.tolerance * 100, range: 0...100, unit: "%") { v in
                        model.updateClip(clip.id, "Tolérance", coalesce: "chromaT") { $0.chroma?.tolerance = v / 100 }
                    }
                    SliderField(title: "Douceur", value: k.softness * 100, range: 0...100, unit: "%") { v in
                        model.updateClip(clip.id, "Douceur", coalesce: "chromaS") { $0.chroma?.softness = v / 100 }
                    }
                    SliderField(title: "Suppression du reflet", value: k.spill * 100, range: 0...100, unit: "%") { v in
                        model.updateClip(clip.id, "Reflet", coalesce: "chromaR") { $0.chroma?.spill = v / 100 }
                    }
                }
            }
        }
        InspectorSection(title: "Style du calque") {
            SliderField(title: "Coins arrondis", value: clip.style.cornerRadius * 100, range: 0...50, unit: "%") { v in
                model.updateClip(clip.id, "Coins arrondis", coalesce: "styleC") { $0.style.cornerRadius = v / 100 }
            }
            SliderField(title: "Bordure", value: clip.style.borderWidth * 100, range: 0...10, unit: "%", fractionDigits: 1) { v in
                model.updateClip(clip.id, "Bordure", coalesce: "styleB") { $0.style.borderWidth = v / 100 }
            }
            if clip.style.borderWidth > 0 {
                ColorPicker("Couleur de la bordure", selection: Binding(get: { clip.style.borderColor.cgColor }, set: { c in
                    model.updateClip(clip.id, "Couleur de la bordure", coalesce: "styleBC") { $0.style.borderColor = RGBA(cgColor: c) }
                }))
            }
            SliderField(title: "Ombre portée", value: clip.style.shadow * 100, range: 0...100, unit: "%") { v in
                model.updateClip(clip.id, "Ombre du calque", coalesce: "styleO") { $0.style.shadow = v / 100 }
            }
        }
    }
}
