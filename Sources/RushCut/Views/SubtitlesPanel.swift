import SwiftUI
import AVFoundation

/// Onglet « Sous-titres » : génération automatique, liste modifiable, import/export, voix.
struct SubtitlesLibrary: View {
    @ObservedObject var model: EditorModel
    @AppStorage("sousTitres.langue") private var language = "fr-FR"
    @AppStorage("voix.identifiant") private var voiceID = ""
    @AppStorage("voix.debit") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var voices: [SpeechSynth.Voice] = []

    var body: some View {
        let cues = model.project.subtitleClips
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InspectorSection(title: "Sous-titres automatiques") {
                    Picker("Langue parlée", selection: $language) {
                        ForEach(Transcriber.languages) { Text($0.name).tag($0.id) }
                    }
                    Button {
                        model.generateSubtitles(language: language)
                    } label: {
                        Label(cues.isEmpty ? "Générer les sous-titres" : "Regénérer (remplace les sous-titres)", systemImage: "captions.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.subtitleBusy)
                    if model.subtitleBusy { ProgressView().controlSize(.small) }
                    if let status = model.subtitleStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("La reconnaissance se fait sur votre Mac, sans envoyer le son sur Internet. La première fois, macOS télécharge le modèle de la langue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                InspectorSection(title: "Fichiers") {
                    HStack {
                        Button("Importer .srt / .vtt…") { model.importSubtitlesPanel() }
                        Menu("Exporter") {
                            ForEach(SubtitleFormat.allCases) { f in Button(f.label) { model.exportSubtitlesPanel(f) } }
                        }
                        .disabled(cues.isEmpty)
                        .fixedSize()
                    }
                    .controlSize(.small)
                }
                if !cues.isEmpty {
                    InspectorSection(title: "\(cues.count) sous-titres") {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(cues) { clip in
                                SubtitleRow(model: model, clip: clip)
                            }
                        }
                        Button("Supprimer tous les sous-titres", role: .destructive) {
                            model.apply("Supprimer les sous-titres") { $0.setSubtitles([], replace: true) }
                        }
                        .controlSize(.small)
                    }
                }
                TranslateSubtitlesSection(model: model)
                InspectorSection(title: "Voix de synthèse") {
                    Picker("Voix", selection: $voiceID) {
                        Text("Voix française par défaut").tag("")
                        ForEach(voices) { v in Text("\(v.name) (\(v.language), \(v.quality))").tag(v.id) }
                    }
                    SliderField(title: "Débit", value: rate * 100, range: 20...80) { rate = $0 / 100 }
                    HStack {
                        Button("Écouter") {
                            let text = model.singleSelection?.text?.string ?? "Bonjour, voici la voix choisie."
                            VoicePreview.shared.say(text, voiceID: voiceID.isEmpty ? nil : voiceID, rate: Float(rate))
                        }
                        Button("Lire le texte sélectionné") {
                            if let id = model.singleSelection?.id { model.speak(id, voiceID: voiceID.isEmpty ? nil : voiceID, rate: Float(rate)) }
                        }
                        .disabled(model.singleSelection?.text == nil || model.subtitleBusy)
                    }
                    .controlSize(.small)
                    Text("Crée un fichier audio avec la voix choisie, placé sous le texte. Pour plus de voix : Réglages Système › Accessibilité › Contenu énoncé.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button("Importer des voix enregistrées (lot)…") { model.batchImportVoicesPanel() }
                        .controlSize(.small)
                        .help("Fichiers audio d'un studio ou d'un service de voix : placés dans l'ordre de leur nom, alignés sur les textes s'il y en a assez.")
                }
            }
            .padding(10)
        }
        .onAppear { if voices.isEmpty { voices = SpeechSynth.voices(languagePrefix: nil).filter { ["fr", "en", "de", "it", "es"].contains(String($0.language.prefix(2))) } } }
    }
}

private struct SubtitleRow: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    @State private var draft = ""

    var body: some View {
        let selected = model.selection.contains(clip.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button {
                    model.select(clip.id, extend: false)
                    model.playback.seek(to: clip.start)
                } label: {
                    Text("\(clip.start.timecode(fps: model.fps)) → \(clip.end.timecode(fps: model.fps))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    model.apply("Supprimer le sous-titre") { p in
                        for ti in p.tracks.indices { p.tracks[ti].clips.removeAll { $0.id == clip.id } }
                    }
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(selected ? 0.35 : 0.2)))
                .onAppear { draft = clip.text?.string ?? "" }
                .onChange(of: clip.text?.string ?? "") { _, v in if v != draft { draft = v } }
                .onSubmit { model.updateSubtitleText(clip.id, draft) }
                .onChange(of: draft) { _, v in if v != clip.text?.string { model.updateSubtitleText(clip.id, v) } }
        }
    }
}

/// Lecture immédiate d'une voix (sans créer de fichier).
@MainActor
final class VoicePreview {
    static let shared = VoicePreview()
    private let synthesizer = AVSpeechSynthesizer()

    func say(_ text: String, voiceID: String?, rate: Float) {
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: "fr-FR")
        u.rate = rate
        synthesizer.speak(u)
    }
}
