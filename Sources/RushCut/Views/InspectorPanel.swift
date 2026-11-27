import SwiftUI
import AppKit
import AVFoundation

/// Inspecteur : réglages de l'élément sélectionné, ou du projet si rien n'est sélectionné.
struct InspectorPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let clip = model.singleSelection {
                        ClipInspector(model: model, clip: clip)
                    } else if model.selection.count > 1 {
                        Text("\(model.selection.count) éléments sélectionnés")
                            .foregroundStyle(.secondary)
                        Button("Supprimer la sélection", role: .destructive) { model.deleteSelection() }
                    } else {
                        ProjectInspector(model: model)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.panel)
    }

    private var title: String {
        guard let clip = model.singleSelection else {
            return model.selection.count > 1 ? "Sélection" : "Projet"
        }
        if clip.isText { return "Texte" }
        if clip.isSticker { return "Autocollant" }
        if clip.isEffectOnly { return clip.filter != nil && clip.effects.isEmpty ? "Filtre" : "Effet" }
        switch model.project.media(clip.mediaID)?.kind {
        case .image: return "Image"
        case .audio: return "Audio"
        default: return model.project.trackIndex(of: clip.id).map { model.project.tracks[$0].kind == .audio } == true ? "Audio" : "Vidéo"
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }
}

// MARK: - Projet

struct ProjectInspector: View {
    @ObservedObject var model: EditorModel
    @State private var name = ""

    var body: some View {
        let s = model.project.settings
        InspectorSection(title: "Projet") {
            TextField("Nom du projet", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitName() }
                .onAppear { name = model.project.name }
                .onChange(of: name) { _, _ in commitName() }
            LabeledContent("Format", value: "\(s.formatLabel) · \(s.width)×\(s.height)")
            Picker("Images par seconde", selection: Binding(get: { s.frameRate }, set: { v in model.updateSettings("Fréquence d'images") { $0.frameRate = v } })) {
                ForEach(ProjectSettings.supportedFrameRates, id: \.self) { Text("\($0) i/s").tag($0) }
            }
        }
        InspectorSection(title: "Fond") {
            Picker("Fond", selection: Binding(get: { s.backgroundMode }, set: { v in model.updateSettings("Type de fond") { $0.backgroundMode = v } })) {
                ForEach(BackgroundMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ColorPicker("Couleur du fond", selection: Binding(get: { s.backgroundColor.cgColor },
                                                             set: { c in model.updateSettings("Couleur du fond", coalesce: "fond") { $0.backgroundColor = RGBA(cgColor: c) } }),
                        supportsOpacity: false)
            Text("Le fond apparaît quand une vidéo ne remplit pas tout le cadre (par exemple une vidéo 16:9 dans un projet 9:16). « Flou de la vidéo » remplit les bords avec la vidéo principale floutée.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        InspectorSection(title: "Astuce") {
            Text("Sélectionnez un clip dans la timeline pour régler sa position, sa taille, son volume ou son texte.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != model.project.name { model.renameProject(trimmed) }
    }
}

// MARK: - Clip

struct ClipInspector: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    private var media: MediaRef? { model.project.media(clip.mediaID) }
    private var onAudioTrack: Bool {
        model.project.trackIndex(of: clip.id).map { model.project.tracks[$0].kind == .audio } ?? false
    }
    private var isVisual: Bool { !onAudioTrack && (clip.isText || media?.hasVideo == true) }
    private var hasAudio: Bool {
        guard let media else { return false }
        return onAudioTrack || (media.kind == .video && media.hasAudio && !clip.audio.isMuted) || media.kind == .audio
    }

    private func update(_ name: String, _ key: String, _ body: @escaping (inout Clip) -> Void) {
        model.updateClip(clip.id, name, coalesce: key, body)
    }

    private var tabs: [InspectorTab] {
        if clip.isEffectOnly { return clip.effects.isEmpty && clip.filter != nil ? [.ajuster] : [.effets] }
        if clip.isText { return [.texte, .base, .animation, .effets, .incrustation] }
        if clip.isSticker { return [.base, .animation, .effets, .incrustation] }
        if onAudioTrack || media?.kind == .audio { return [.audio, .vitesse, .auto] }
        var list: [InspectorTab] = [.base, .animation]
        if media?.kind == .video { list.append(.vitesse) }
        list += [.ajuster, .masque, .effets, .incrustation]
        if hasAudio { list.append(.audio) }
        list.append(.auto)
        return list
    }

    var body: some View {
        let tabs = self.tabs
        let tab = tabs.contains(model.inspectorTab) ? model.inspectorTab : tabs[0]
        if tabs.count > 1 {
            InspectorTabBar(tabs: tabs, selection: tab) { model.inspectorTab = $0 }
        }
        switch tab {
        case .texte:
            if let text = clip.text { TextInspector(model: model, clip: clip, text: text) }
        case .base: baseTab
        case .animation: AnimationTab(model: model, clip: clip)
        case .vitesse: SpeedTab(model: model, clip: clip)
        case .ajuster:
            if clip.isEffectOnly { FilterSection(model: model, clip: clip) } else { AdjustTab(model: model, clip: clip) }
        case .masque: MaskTab(model: model, clip: clip)
        case .effets: EffectsTab(model: model, clip: clip)
        case .incrustation: OverlayTab(model: model, clip: clip)
        case .audio: audioTab
        case .auto: SmartTab(model: model, clip: clip)
        }
        InspectorSection(title: "Attributs") {
            HStack {
                Button("Copier les attributs") { model.copyAttributes() }
                Button("Coller") { model.pasteAttributes() }
                    .disabled(model.attributeClipboard == nil)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var baseTab: some View {
        InspectorSection(title: "Clip") {
            LabeledContent("Nom", value: clip.isText ? "Texte" : clip.name)
            LabeledContent("Début", value: clip.start.timecode(fps: model.fps))
            LabeledContent("Durée", value: clip.duration.timecode(fps: model.fps))
            if let media {
                LabeledContent("Source", value: media.kind == .audio ? media.kind.label : "\(media.kind.label) \(media.width)×\(media.height)")
            }
            if clip.isText || clip.isSticker || media?.kind == .image {
                SliderField(title: "Durée (s)", value: clip.duration.seconds, range: 0.1...120, fractionDigits: 1) { v in
                    update("Durée", "duree") { $0.duration = RTime(seconds: v).snapped(fps: model.fps) }
                }
            }
            if clip.isSticker {
                ColorPicker("Couleur", selection: Binding(get: { clip.stickerColor.cgColor }, set: { c in
                    update("Couleur de l'autocollant", "stickerC") { $0.stickerColor = RGBA(cgColor: c) }
                }), supportsOpacity: false)
            }
        }

        if isVisual || clip.isSticker {
            InspectorSection(title: "Position et taille") {
                if !clip.isText && !clip.isSticker {
                    Picker("Cadrage", selection: Binding(get: { clip.fit }, set: { v in update("Cadrage", "fit") { $0.fit = v } })) {
                        ForEach([FitMode.fit, .fill, .stretch], id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                KeyframeSlider(model: model, playback: model.playback, clip: clip, prop: .scale, factor: 100, range: 5...500, unit: "%")
                KeyframeSlider(model: model, playback: model.playback, clip: clip, prop: .positionX, factor: 100, range: -100...100, unit: "%")
                KeyframeSlider(model: model, playback: model.playback, clip: clip, prop: .positionY, factor: 100, range: -100...100, unit: "%")
                KeyframeSlider(model: model, playback: model.playback, clip: clip, prop: .rotation, range: -180...180, unit: "°")
                KeyframeSlider(model: model, playback: model.playback, clip: clip, prop: .opacity, factor: 100, range: 0...100, unit: "%")
                HStack {
                    Toggle("Miroir horizontal", isOn: Binding(get: { clip.transform.flipH }, set: { v in update("Miroir", "flipH") { $0.transform.flipH = v } }))
                    Toggle("Vertical", isOn: Binding(get: { clip.transform.flipV }, set: { v in update("Miroir", "flipV") { $0.transform.flipV = v } }))
                }
                .toggleStyle(.checkbox)
                KeyframeNavigator(model: model, playback: model.playback, clip: clip, props: [.scale, .positionX, .positionY, .rotation, .opacity])
                Button("Réinitialiser") {
                    update("Réinitialiser la position", "reset") { c in
                        c.transform = Transform(); c.opacity = 1
                        for p in [KeyProp.scale, .positionX, .positionY, .rotation, .opacity] { c.keyframes[p.rawValue] = nil }
                    }
                }
            }
            if !clip.isText && !clip.isSticker, let media {
                CropInspector(model: model, clip: clip, source: media.pixelSize)
            }
        }
        ClipToolsSection(model: model, clip: clip)
    }

    @ViewBuilder private var audioTab: some View {
        InspectorSection(title: "Audio") {
            KeyframeSlider(model: model, playback: model.playback, clip: clip, prop: .volume, range: -60...20, unit: "dB", fractionDigits: 1)
            KeyframeNavigator(model: model, playback: model.playback, clip: clip, props: [.volume])
            HStack {
                Text("Normaliser").font(.caption)
                Button("Réseaux (−14 LUFS)") { model.normalizeLoudness(Array(model.selection), target: -14) }
                Button("TV (−23)") { model.normalizeLoudness(Array(model.selection), target: -23) }
            }
            .controlSize(.small)
            .help("Mesure la sonie du son et règle le volume pour atteindre la cible.")
            let maxFade = max(0.1, min(10, clip.duration.seconds / 2))
            SliderField(title: "Fondu d'ouverture", value: clip.audio.fadeIn.seconds, range: 0...maxFade, unit: "s", fractionDigits: 2) { v in
                update("Fondu d'ouverture", "fadeIn") { $0.audio.fadeIn = RTime(seconds: v).snapped(fps: model.fps) }
            }
            SliderField(title: "Fondu de fermeture", value: clip.audio.fadeOut.seconds, range: 0...maxFade, unit: "s", fractionDigits: 2) { v in
                update("Fondu de fermeture", "fadeOut") { $0.audio.fadeOut = RTime(seconds: v).snapped(fps: model.fps) }
            }
            if !onAudioTrack && media?.kind == .video {
                Button("Détacher l'audio") { model.detachAudio() }
            }
        }
        if media != nil {
            Button { model.removeSilences(clip.id) } label: { Label("Supprimer les silences", systemImage: "waveform.path.badge.minus") }
                .controlSize(.small)
                .disabled(model.toolStatus != nil)
        }
        InspectorSection(title: "Effet de voix") {
            Picker("Effet", selection: Binding(get: { clip.audio.voiceEffect ?? "" }, set: { v in
                update("Effet de voix", "voix") { $0.audio.voiceEffect = v.isEmpty ? nil : v }
            })) {
                Text("Aucun").tag("")
                ForEach(VoiceEffects.all) { Text($0.name).tag($0.id) }
            }
            Text("Le son traité est préparé en arrière-plan ; l'aperçu se met à jour au bout d'un instant.")
                .font(.caption).foregroundStyle(.secondary)
        }
        InspectorSection(title: "Nettoyage et mixage") {
            SliderField(title: "Réduction de bruit", value: clip.audio.denoise * 100, range: 0...100, unit: "%") { v in
                update("Réduction de bruit", "denoise") { $0.audio.denoise = v / 100 }
            }
            Text("Atténue le souffle, le ronflement et les bruits de fond entre les phrases.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Baisser sous les autres sons (ducking)", isOn: Binding(get: { clip.audio.duckDB < 0 }, set: { v in
                update("Atténuation automatique", "duck") { $0.audio.duckDB = v ? -12 : 0 }
            }))
            if clip.audio.duckDB < 0 {
                SliderField(title: "Atténuation", value: clip.audio.duckDB, range: -30...(-3), unit: "dB") { v in
                    update("Atténuation automatique", "duckA") { $0.audio.duckDB = v }
                }
                Text("À utiliser sur la musique : elle baisse toute seule quand une voix ou un autre son joue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CropInspector: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    let source: CGSize

    private struct AspectChoice: Identifiable {
        let label: String
        let ratio: Double
        var id: String { label }
    }

    private static let choices: [AspectChoice] = [
        AspectChoice(label: "Libre", ratio: 0),
        AspectChoice(label: "16:9", ratio: 16.0 / 9.0),
        AspectChoice(label: "9:16", ratio: 9.0 / 16.0),
        AspectChoice(label: "1:1", ratio: 1),
        AspectChoice(label: "4:5", ratio: 0.8),
    ]

    private func applyAspect(_ ratio: Double) {
        let size = source
        model.updateClip(clip.id, "Recadrage") { c in
            c.crop = ratio == 0 ? CropRect() : Geometry.crop(forAspect: ratio, source: size)
        }
    }

    var body: some View {
        InspectorSection(title: "Recadrage") {
            HStack {
                ForEach(Self.choices) { choice in
                    Button(choice.label) { applyAspect(choice.ratio) }
                        .controlSize(.small)
                }
            }
            SliderField(title: "Gauche", value: clip.crop.left * 100, range: 0...45, unit: "%") { v in
                model.updateClip(clip.id, "Recadrage", coalesce: "cropL") { $0.crop.left = v / 100 }
            }
            SliderField(title: "Droite", value: clip.crop.right * 100, range: 0...45, unit: "%") { v in
                model.updateClip(clip.id, "Recadrage", coalesce: "cropR") { $0.crop.right = v / 100 }
            }
            SliderField(title: "Haut", value: clip.crop.top * 100, range: 0...45, unit: "%") { v in
                model.updateClip(clip.id, "Recadrage", coalesce: "cropT") { $0.crop.top = v / 100 }
            }
            SliderField(title: "Bas", value: clip.crop.bottom * 100, range: 0...45, unit: "%") { v in
                model.updateClip(clip.id, "Recadrage", coalesce: "cropB") { $0.crop.bottom = v / 100 }
            }
        }
    }
}

struct TextInspector: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    let text: TextContent
    @State private var draft = ""
    @State private var families: [String] = []

    private func update(_ name: String, _ key: String, _ body: @escaping (inout TextContent) -> Void) {
        model.updateClip(clip.id, name, coalesce: key) { c in
            guard var t = c.text else { return }
            body(&t)
            c.text = t
            c.name = String(t.string.prefix(30))
        }
    }

    private func speakText() {
        let stored = UserDefaults.standard.string(forKey: "voix.identifiant") ?? ""
        let voice: String? = stored.isEmpty ? nil : stored
        let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        let rate: Double = UserDefaults.standard.object(forKey: "voix.debit") as? Double ?? defaultRate
        model.speak(clip.id, voiceID: voice, rate: Float(rate))
    }

    private func color(_ keyPath: WritableKeyPath<TextContent, RGBA>, _ name: String) -> Binding<CGColor> {
        Binding(get: { text[keyPath: keyPath].cgColor },
                set: { c in update(name, name) { $0[keyPath: keyPath] = RGBA(cgColor: c) } })
    }

    var body: some View {
        InspectorSection(title: "Texte") {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                .onAppear {
                    draft = text.string
                    if families.isEmpty { families = FontLibrary.families }
                }
                .onChange(of: clip.id) { _, _ in draft = text.string }
                .onChange(of: text.string) { _, v in if v != draft { draft = v } }
                .onChange(of: draft) { _, v in
                    if v != text.string { update("Modifier le texte", "texte") { $0.string = v } }
                }
            HStack {
                Picker("Police", selection: Binding(get: { text.fontName }, set: { v in update("Police", "police") { $0.fontName = v } })) {
                    if !families.contains(text.fontName) { Text(text.fontName).tag(text.fontName) }
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Button {
                    let added = FontLibrary.importFonts()
                    families = FontLibrary.families
                    if let first = added.first { update("Police", "police") { $0.fontName = first } }
                } label: { Image(systemName: "plus") }
                    .help("Importer une police (.ttf, .otf)")
            }
            SliderField(title: "Taille", value: text.fontSize * 100, range: 1...30, unit: "%", fractionDigits: 1) { v in
                update("Taille du texte", "taille") { $0.fontSize = v / 100 }
            }
            HStack {
                ColorPicker("Couleur", selection: color(\.color, "Couleur du texte"), supportsOpacity: true)
                Spacer()
                Toggle("Gras", isOn: Binding(get: { text.bold }, set: { v in update("Gras", "gras") { $0.bold = v } }))
                Toggle("Italique", isOn: Binding(get: { text.italic }, set: { v in update("Italique", "italique") { $0.italic = v } }))
            }
            .toggleStyle(.button)
            Picker("Alignement", selection: Binding(get: { text.alignment }, set: { v in update("Alignement", "alignement") { $0.alignment = v } })) {
                ForEach(TextAlignmentMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            SliderField(title: "Interlettrage", value: text.letterSpacing * 100, range: -10...50, unit: "%") { v in
                update("Interlettrage", "kern") { $0.letterSpacing = v / 100 }
            }
            SliderField(title: "Interligne", value: text.lineSpacing * 100, range: 0...100, unit: "%") { v in
                update("Interligne", "interligne") { $0.lineSpacing = v / 100 }
            }
        }
        if text.isSubtitle {
            InspectorSection(title: "Sous-titre") {
                Button("Appliquer ce style et cette position à tous les sous-titres") { model.applyStyleToAllSubtitles(from: clip) }
                    .controlSize(.small)
                Button("Ouvrir la liste des sous-titres") { model.libraryTab = .captions }
                    .controlSize(.small)
            }
        }
        InspectorSection(title: "Voix") {
            Button("Lire ce texte avec une voix de synthèse") { speakText() }
                .controlSize(.small)
                .disabled(model.subtitleBusy)
        }
        InspectorSection(title: "Style du texte") {
            Toggle("Contour", isOn: Binding(get: { text.strokeEnabled }, set: { v in update("Contour", "contour") { $0.strokeEnabled = v } }))
            if text.strokeEnabled {
                ColorPicker("Couleur du contour", selection: color(\.strokeColor, "Couleur du contour"))
                SliderField(title: "Épaisseur", value: text.strokeWidth * 100, range: 1...30, unit: "%") { v in
                    update("Épaisseur du contour", "contourE") { $0.strokeWidth = v / 100 }
                }
            }
            Divider()
            Toggle("Ombre", isOn: Binding(get: { text.shadowEnabled }, set: { v in update("Ombre", "ombre") { $0.shadowEnabled = v } }))
            if text.shadowEnabled {
                ColorPicker("Couleur de l'ombre", selection: color(\.shadowColor, "Couleur de l'ombre"), supportsOpacity: true)
                SliderField(title: "Flou", value: text.shadowBlur * 100, range: 0...60, unit: "%") { v in
                    update("Flou de l'ombre", "ombreF") { $0.shadowBlur = v / 100 }
                }
                SliderField(title: "Décalage", value: text.shadowOffset * 100, range: 0...30, unit: "%") { v in
                    update("Décalage de l'ombre", "ombreD") { $0.shadowOffset = v / 100 }
                }
            }
            Divider()
            Toggle("Fond", isOn: Binding(get: { text.backgroundEnabled }, set: { v in update("Fond du texte", "fondT") { $0.backgroundEnabled = v } }))
            if text.backgroundEnabled {
                ColorPicker("Couleur du fond", selection: color(\.backgroundColor, "Couleur du fond du texte"), supportsOpacity: true)
                SliderField(title: "Marge", value: text.backgroundPadding * 100, range: 0...100, unit: "%") { v in
                    update("Marge du fond", "fondM") { $0.backgroundPadding = v / 100 }
                }
                SliderField(title: "Coins arrondis", value: text.backgroundCornerRadius * 100, range: 0...100, unit: "%") { v in
                    update("Coins du fond", "fondC") { $0.backgroundCornerRadius = v / 100 }
                }
            }
        }
    }
}
