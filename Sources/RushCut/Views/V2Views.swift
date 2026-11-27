import SwiftUI
import AppKit
import AVFoundation
import Translation
import FoundationModels

// MARK: - Onglet « Auto » de l'inspecteur

struct SmartTab: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    @AppStorage("sousTitres.langue") private var language = "fr-FR"
    @State private var stabilizeStrength = 0.6
    @State private var editByText = false

    var body: some View {
        let media = model.project.media(clip.mediaID)
        let isVideo = media?.kind == .video
        let visual = isVideo || media?.kind == .image
        if visual {
            InspectorSection(title: "Détourage automatique") {
                Picker("Garder", selection: Binding(get: { clip.cutout?.rawValue ?? "" }, set: { v in
                    model.updateClip(clip.id, "Détourage") { $0.cutout = CutoutMode(rawValue: v) }
                })) {
                    Text("Tout (pas de détourage)").tag("")
                    ForEach(CutoutMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Text("Retire le fond sans écran vert, image par image, sur votre Mac. Placez une autre vidéo ou une image dessous pour changer de décor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            InspectorSection(title: "Retouche du visage") {
                SliderField(title: "Lissage de la peau", value: clip.retouch.smooth * 100, range: 0...100, unit: "%") { v in
                    model.updateClip(clip.id, "Lissage", coalesce: "lissage") { $0.retouch.smooth = v / 100 }
                }
                SliderField(title: "Éclat", value: clip.retouch.brighten * 100, range: 0...100, unit: "%") { v in
                    model.updateClip(clip.id, "Éclat", coalesce: "eclat") { $0.retouch.brighten = v / 100 }
                }
            }
        }
        if isVideo {
            InspectorSection(title: "Cadrage et mouvement") {
                Button { model.autoReframe(clip.id) } label: { Label("Recadrage automatique sur le sujet", systemImage: "person.crop.rectangle") }
                Button { model.convertToVertical() } label: { Label("Passer tout le projet en 9:16 (recadré)", systemImage: "rectangle.portrait") }
                Divider()
                SliderField(title: "Force de la stabilisation", value: stabilizeStrength * 100, range: 0...100, unit: "%") { stabilizeStrength = $0 / 100 }
                Button { model.stabilize(clip.id, strength: stabilizeStrength) } label: { Label("Stabiliser", systemImage: "camera.metering.center.weighted") }
                Button { model.smoothSlowMotion(clip.id) } label: { Label("Ralenti fluide (images intermédiaires)", systemImage: "tortoise") }
                    .disabled(clip.speed.rate >= 0.99)
                Button { model.splitAtSceneChanges(clip.id) } label: { Label("Couper aux changements de plan", systemImage: "film.stack") }
            }
            .buttonStyle(.borderless)
            .disabled(model.toolStatus != nil)
        }
        if media?.hasAudio == true || media?.kind == .audio {
            InspectorSection(title: "Parole et rythme") {
                Picker("Langue", selection: $language) {
                    ForEach(Transcriber.languages) { Text($0.name).tag($0.id) }
                }
                Button { model.removeFillerWords(clip.id, language: language) } label: { Label("Supprimer les « euh » et « hum »", systemImage: "text.badge.minus") }
                Button { editByText = true } label: { Label("Monter par le texte…", systemImage: "text.cursor") }
                Button { model.markBeats(clip.id) } label: { Label("Marquer les temps de la musique", systemImage: "metronome") }
            }
            .buttonStyle(.borderless)
            .disabled(model.toolStatus != nil)
            .sheet(isPresented: $editByText) { EditByTextSheet(model: model, clipID: clip.id, language: language) }
        }
    }
}

// MARK: - Courbes de vitesse

struct SpeedCurveSection: View {
    @ObservedObject var model: EditorModel
    let clip: Clip

    var body: some View {
        InspectorSection(title: "Courbe de vitesse") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], spacing: 6) {
                Button("Aucune") { model.apply("Vitesse constante") { $0.setSpeedCurve(clip.id, points: [], name: nil) } }
                    .buttonStyle(.bordered)
                    .tint(clip.speed.curve.isEmpty ? .accentColor : nil)
                ForEach(SpeedCurves.presets) { p in
                    Button(p.name) { model.apply("Courbe « \(p.name) »") { $0.setSpeedCurve(clip.id, points: p.points, name: p.name) } }
                        .buttonStyle(.bordered)
                        .tint(clip.speed.curveName == p.name ? .accentColor : nil)
                }
            }
            .controlSize(.small)
            if !clip.speed.curve.isEmpty {
                CurveEditor(points: clip.speed.curve) { points in
                    model.apply("Modifier la courbe", coalesce: "courbe") { $0.setSpeedCurve(clip.id, points: points, name: "Personnalisée") }
                }
                .frame(height: 110)
                Text("Glissez les points vers le haut (plus rapide) ou vers le bas (ralenti). Durée obtenue : \(clip.duration.timecode(fps: model.fps)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Graphique de la courbe : vitesse sur une échelle logarithmique de ×0,1 à ×10.
struct CurveEditor: View {
    let points: [SpeedPoint]
    let onChange: ([SpeedPoint]) -> Void
    @State private var dragging: Int?
    @State private var draft: [SpeedPoint] = []

    private func y(_ rate: Double, _ h: CGFloat) -> CGFloat { h * CGFloat(1 - (log10(max(0.1, min(10, rate))) + 1) / 2) }
    private func rate(_ y: CGFloat, _ h: CGFloat) -> Double { pow(10, Double(1 - y / h) * 2 - 1) }

    var body: some View {
        GeometryReader { g in
            let pts = draft.isEmpty ? points : draft
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3))
                Path { p in p.move(to: CGPoint(x: 0, y: y(1, g.size.height))); p.addLine(to: CGPoint(x: g.size.width, y: y(1, g.size.height))) }
                    .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { p in
                    for (i, pt) in pts.enumerated() {
                        let c = CGPoint(x: g.size.width * pt.position, y: y(pt.rate, g.size.height))
                        if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 2)
                ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .position(x: g.size.width * pt.position, y: y(pt.rate, g.size.height))
                        .gesture(DragGesture().onChanged { v in
                            if draft.isEmpty { draft = points }
                            draft[i].rate = (rate(v.location.y, g.size.height) * 100).rounded() / 100
                        }.onEnded { _ in
                            onChange(draft)
                            draft = []
                        })
                }
            }
        }
    }
}

// MARK: - Montage par le texte

/// Disposition en lignes (les mots passent à la ligne quand il n'y a plus de place).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

struct EditByTextSheet: View {
    @ObservedObject var model: EditorModel
    let clipID: UUID
    let language: String
    @Environment(\.dismiss) private var dismiss
    @State private var words: [WordTiming] = []
    @State private var removed: Set<Int> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monter par le texte").font(.title2.weight(.semibold))
            Text("Cliquez sur les mots à supprimer de la vidéo (cliquez de nouveau pour les garder). Les morceaux restants se recollent.")
                .font(.callout).foregroundStyle(.secondary)
            if loading {
                HStack { ProgressView().controlSize(.small); Text(model.toolStatus ?? "Transcription…") }
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if let error {
                Text(error).foregroundStyle(.red).frame(minHeight: 120)
            } else {
                ScrollView {
                    FlowLayout {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            let off = removed.contains(i)
                            Text(w.text)
                                .font(.system(size: 14))
                                .strikethrough(off, color: .red)
                                .foregroundStyle(off ? Color.red.opacity(0.8) : Color.primary)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(off ? Color.red.opacity(0.12) : Color.clear))
                                .onTapGesture { if off { removed.remove(i) } else { removed.insert(i) } }
                                .help(w.start.timecode(fps: model.fps))
                        }
                    }
                    .padding(8)
                }
                .frame(height: 320)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
            }
            HStack {
                Text(removed.isEmpty ? "" : "\(removed.count) mots à supprimer").font(.callout)
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Appliquer") {
                    let ranges = mergedRanges()
                    model.apply("Montage par le texte") { $0.removeRanges(ranges, from: clipID) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(removed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640)
        .task {
            do { words = try await model.transcribeClip(clipID, language: language) }
            catch { self.error = error.localizedDescription }
            model.toolStatus = nil
            loading = false
        }
    }

    /// Mots supprimés regroupés en plages continues (le silence entre deux mots supprimés part aussi).
    private func mergedRanges() -> [(RTime, RTime)] {
        var ranges: [(RTime, RTime)] = []
        for i in removed.sorted() {
            let w = words[i]
            let start = i > 0 && !removed.contains(i - 1) ? max(words[i - 1].end, w.start - RTime(seconds: 0.05)) : w.start
            let end = i + 1 < words.count ? min(words[i + 1].start, w.end + RTime(seconds: 0.05)) : w.end + RTime(seconds: 0.1)
            if let last = ranges.last, removed.contains(i - 1) { ranges[ranges.count - 1] = (last.0, end) }
            else { ranges.append((start, end)) }
        }
        return ranges
    }
}

// MARK: - Traduction des sous-titres

struct TranslateSubtitlesSection: View {
    @ObservedObject var model: EditorModel
    @State private var target = "en"
    @State private var configuration: TranslationSession.Configuration?
    @State private var message: String?
    @AppStorage("sousTitres.langue") private var spoken = "fr-FR"

    private let targets: [Transcriber.Language] = [("en", "Anglais"), ("fr", "Français"), ("de", "Allemand"), ("it", "Italien"),
                                                   ("es", "Espagnol"), ("pt", "Portugais"), ("nl", "Néerlandais"), ("ja", "Japonais"), ("zh", "Chinois")]
        .map { Transcriber.Language(id: $0.0, name: $0.1) }

    var body: some View {
        InspectorSection(title: "Traduire les sous-titres") {
            Picker("Vers", selection: $target) {
                ForEach(targets) { Text($0.name).tag($0.id) }
            }
            Button("Traduire (remplace le texte des sous-titres)") {
                let source = Locale.Language(identifier: String(spoken.prefix(2)))
                if configuration == nil || configuration?.target?.minimalIdentifier != target {
                    configuration = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: target))
                } else {
                    configuration?.invalidate()
                }
            }
            .controlSize(.small)
            .disabled(model.project.subtitleClips.isEmpty)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("La traduction se fait sur le Mac. macOS peut demander de télécharger la langue la première fois.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .translationTask(configuration) { session in
            let clips = model.project.subtitleClips
            let requests = clips.map { TranslationSession.Request(sourceText: $0.text?.string ?? "", clientIdentifier: $0.id.uuidString) }
            do {
                let responses = try await session.translations(from: requests)
                let map = Dictionary(uniqueKeysWithValues: responses.compactMap { r in r.clientIdentifier.flatMap(UUID.init(uuidString:)).map { ($0, r.targetText) } })
                model.apply("Traduire les sous-titres") { p in
                    for (id, text) in map { p.updateClip(id) { c in c.text?.string = text; c.text?.words = []; c.name = String(text.prefix(30)) } }
                }
                message = "\(map.count) sous-titres traduits."
            } catch {
                message = "Traduction impossible : \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Charte graphique

struct BrandKitSection: View {
    @ObservedObject var model: EditorModel
    @State private var kit = BrandKit.load()

    var body: some View {
        InspectorSection(title: "Charte graphique") {
            HStack(spacing: 6) {
                ForEach(kit.colors.indices, id: \.self) { i in
                    ColorPicker("", selection: Binding(get: { kit.colors[i].cgColor }, set: { kit.colors[i] = RGBA(cgColor: $0); kit.save() }))
                        .labelsHidden()
                        .frame(width: 26)
                    }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(kit.colors.indices, id: \.self) { i in
                    Button { model.applyBrandColor(kit.colors[i]) } label: {
                        Circle().fill(Color(cgColor: kit.colors[i].cgColor)).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .help("Appliquer cette couleur au texte ou à l'autocollant sélectionné")
                }
                Spacer()
            }
            HStack {
                TextField("Police des titres", text: $kit.titleFont).onSubmit { kit.save() }
                Button("Appliquer") { model.applyBrandFont(kit.titleFont) }
            }
            HStack {
                TextField("Police du texte", text: $kit.bodyFont).onSubmit { kit.save() }
                Button("Appliquer") { model.applyBrandFont(kit.bodyFont) }
            }
            HStack {
                Button(kit.logoPath == nil ? "Choisir le logo…" : "Changer le logo…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url {
                        let target = AppPaths.applicationSupport.appendingPathComponent("logo.\(url.pathExtension)")
                        try? FileManager.default.removeItem(at: target)
                        try? FileManager.default.copyItem(at: url, to: target)
                        kit.logoPath = target.path
                        kit.save()
                    }
                }
                Button("Ajouter le logo au projet") { model.addBrandLogo() }
                    .disabled(kit.logoPath == nil)
            }
        }
        .controlSize(.small)
        .onChange(of: kit) { _, k in k.save() }
    }
}

// MARK: - Webcam

@MainActor
final class WebcamRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?
    private var continuation: CheckedContinuation<URL?, Never>?

    func configure() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        guard video else {
            errorMessage = "RushCut n'a pas accès à la caméra (Réglages Système › Confidentialité et sécurité › Caméra)."
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) { session.addInput(input) }
        if audio, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let s = session
        Task.detached { s.startRunning() }
    }

    func start(folder: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        output.startRecording(to: folder.appendingPathComponent("Webcam \(stamp).mov"), recordingDelegate: self)
        isRecording = true
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        return await withCheckedContinuation { c in
            continuation = c
            output.stopRecording()
        }
    }

    func shutdown() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.continuation?.resume(returning: FileManager.default.fileExists(atPath: outputFileURL.path) ? outputFileURL : nil)
            self.continuation = nil
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WebcamSheet: View {
    @ObservedObject var model: EditorModel
    @StateObject private var recorder = WebcamRecorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enregistrer avec la caméra").font(.title2.weight(.semibold))
            CameraPreview(session: recorder.session)
                .frame(height: 300)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let e = recorder.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Fermer") { recorder.shutdown(); dismiss() }.disabled(recorder.isRecording)
                Spacer()
                if recorder.isRecording {
                    Button("Arrêter") {
                        Task {
                            let at = model.playhead
                            if let url = await recorder.stop(), let id = await model.importMedia([url]).first { model.dropMedia(id, at: at, target: nil) }
                            recorder.shutdown()
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enregistrer") { recorder.start(folder: model.generatedMediaFolder) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await recorder.configure() }
    }
}

// MARK: - Assistant (Apple Intelligence, sur le Mac)

struct AssistantSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var working = false
    @State private var request = ""

    private var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Activez Apple Intelligence dans Réglages Système pour utiliser l'assistant."
            case .modelNotReady: return "Le modèle d'Apple Intelligence se télécharge encore. Réessayez plus tard."
            default: return "Apple Intelligence n'est pas disponible sur ce Mac."
            }
        }
    }

    private var transcript: String {
        model.project.subtitleClips.compactMap { $0.text?.string }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assistant").font(.title2.weight(.semibold))
            Text("Rédige à partir des sous-titres du projet, avec le modèle d'Apple Intelligence qui tourne sur votre Mac (rien n'est envoyé sur Internet). Il écrit du texte ; il ne crée ni images ni vidéos.")
                .font(.callout).foregroundStyle(.secondary)
            if let availabilityMessage {
                Label(availabilityMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                HStack {
                    Button("Titre et description") { run("Propose 3 titres accrocheurs (moins de 60 caractères) puis une description de 2 phrases pour cette vidéo.") }
                    Button("Hashtags") { run("Propose 10 hashtags pertinents pour cette vidéo, sur une seule ligne.") }
                    Button("Résumé") { run("Résume cette vidéo en 3 points courts.") }
                }
                .disabled(working || transcript.isEmpty)
                if let text = model.singleSelection?.text?.string {
                    Button("Raccourcir le texte sélectionné") {
                        run("Réécris ce texte de vidéo en plus court et plus percutant, sans guillemets : \(text)", transcriptFree: true, replaceSelection: true)
                    }
                    .disabled(working)
                }
                HStack {
                    TextField("Demande libre (ex. « écris une accroche pour l'intro »)", text: $request)
                        .textFieldStyle(.roundedBorder)
                    Button("Envoyer") { run(request) }.disabled(working || request.isEmpty)
                }
                if transcript.isEmpty {
                    Text("Astuce : générez d'abord les sous-titres pour que l'assistant connaisse le contenu de la vidéo.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if working { ProgressView().controlSize(.small) }
            ScrollView {
                Text(output.isEmpty ? " " : output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2)))
            HStack {
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func run(_ instruction: String, transcriptFree: Bool = false, replaceSelection: Bool = false) {
        working = true
        let context = transcriptFree ? "" : "\n\nTranscription de la vidéo :\n\(transcript.prefix(6000))"
        let selected = model.singleSelection?.id
        Task {
            defer { working = false }
            do {
                let session = LanguageModelSession(instructions: "Tu aides à publier des vidéos. Réponds en français, de façon concise.")
                let response = try await session.respond(to: instruction + context)
                output = response.content
                if replaceSelection, let selected {
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.updateClip(selected, "Texte réécrit") { $0.text?.string = text }
                }
            } catch {
                output = "L'assistant n'a pas pu répondre : \(error.localizedDescription)"
            }
        }
    }
}

struct SaveTemplateSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enregistrer comme modèle").font(.title2.weight(.semibold))
            Text("Le modèle garde le format, les pistes, les textes, les effets, les transitions et les sons. Il apparaît dans « Nouveau projet ».")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Nom du modèle", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") {
                    model.saveAsTemplate(name: name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { name = "Modèle — \(model.project.name)" }
    }
}
