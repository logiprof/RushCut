import SwiftUI
import AppKit

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

    var body: some View {
        InspectorSection(title: "Clip") {
            LabeledContent("Nom", value: clip.isText ? "Texte" : clip.name)
            LabeledContent("Début", value: clip.start.timecode(fps: model.fps))
            LabeledContent("Durée", value: clip.duration.timecode(fps: model.fps))
            if let media {
                LabeledContent("Source", value: media.kind == .audio ? media.kind.label : "\(media.kind.label) \(media.width)×\(media.height)")
            }
            if clip.isText || media?.kind == .image {
                SliderField(title: "Durée (s)", value: clip.duration.seconds, range: 0.1...120, fractionDigits: 1) { v in
                    update("Durée", "duree") { $0.duration = RTime(seconds: v).snapped(fps: model.fps) }
                }
            }
        }

        if let text = clip.text {
            TextInspector(model: model, clip: clip, text: text)
        }

        if isVisual {
            InspectorSection(title: "Position et taille") {
                if !clip.isText {
                    Picker("Cadrage", selection: Binding(get: { clip.fit }, set: { v in update("Cadrage", "fit") { $0.fit = v } })) {
                        ForEach([FitMode.fit, .fill, .stretch], id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                SliderField(title: "Échelle", value: clip.transform.scale * 100, range: 5...500, unit: "%") { v in
                    update("Échelle", "echelle") { $0.transform.scale = v / 100 }
                }
                SliderField(title: "Position X", value: clip.transform.positionX * 100, range: -100...100, unit: "%") { v in
                    update("Position", "position") { $0.transform.positionX = v / 100 }
                }
                SliderField(title: "Position Y", value: clip.transform.positionY * 100, range: -100...100, unit: "%") { v in
                    update("Position", "position") { $0.transform.positionY = v / 100 }
                }
                SliderField(title: "Rotation", value: clip.transform.rotation, range: -180...180, unit: "°") { v in
                    update("Rotation", "rotation") { $0.transform.rotation = v }
                }
                HStack {
                    Toggle("Miroir horizontal", isOn: Binding(get: { clip.transform.flipH }, set: { v in update("Miroir", "flipH") { $0.transform.flipH = v } }))
                    Toggle("Vertical", isOn: Binding(get: { clip.transform.flipV }, set: { v in update("Miroir", "flipV") { $0.transform.flipV = v } }))
                }
                .toggleStyle(.checkbox)
                SliderField(title: "Opacité", value: clip.opacity * 100, range: 0...100, unit: "%") { v in
                    update("Opacité", "opacite") { $0.opacity = v / 100 }
                }
                Button("Réinitialiser") { update("Réinitialiser la position", "reset") { $0.transform = Transform(); $0.opacity = 1 } }
            }
            if !clip.isText, let media {
                CropInspector(model: model, clip: clip, source: media.pixelSize)
            }
        }

        if hasAudio {
            InspectorSection(title: "Audio") {
                SliderField(title: "Volume", value: clip.audio.volumeDB, range: -60...0, unit: "dB", fractionDigits: 1) { v in
                    update("Volume", "volume") { $0.audio.volumeDB = v }
                }
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
