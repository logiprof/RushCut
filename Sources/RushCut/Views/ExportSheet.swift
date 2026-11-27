import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Fenêtre d'export : réglages, estimation de la taille, progression, résultat.
struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case settings
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    private enum Preset: String, CaseIterable, Identifiable {
        case custom, youtube1080, youtube4k, social, web, archive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .custom: return "Réglages manuels"
            case .youtube1080: return "YouTube 1080p"
            case .youtube4k: return "YouTube 4K"
            case .social: return "Reels / TikTok / Shorts"
            case .web: return "Site web léger (720p)"
            case .archive: return "Archive (ProRes)"
            }
        }
    }

    @State private var phase: Phase = .settings
    @State private var name = ""
    @State private var folder: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    @State private var preset: Preset = .custom
    @State private var container: ExportContainer = .mp4
    @State private var codec: ExportCodec = .h264
    @State private var resolution: ExportResolution = .p1080
    @State private var frameRate = 30
    @State private var bitrate: BitrateChoice = .recommended
    @State private var customMbps: Double = 10
    @State private var exporter: Exporter?
    @State private var task: Task<Void, Never>?
    @State private var kind: ExportKind = .video
    @State private var onlyRange = false
    @State private var withSubtitles = false

    private var settings: ExportSettings {
        var s = ExportSettings(destination: destination)
        s.container = codec == .prores422 ? .mov : container
        s.codec = codec
        s.resolution = resolution
        s.frameRate = frameRate
        s.bitrateChoice = bitrate
        s.customMbps = customMbps
        if onlyRange {
            s.rangeStart = model.inPoint
            s.rangeEnd = model.outPoint
        }
        return s
    }

    private var destination: URL {
        let ext = kind != .video ? kind.fileExtension : (codec == .prores422 ? "mov" : container.rawValue)
        let clean = ProjectStore.sanitize(name.isEmpty ? model.project.name : name)
        return folder.appendingPathComponent(clean).appendingPathExtension(ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporter").font(.title2.weight(.semibold))
            switch phase {
            case .settings: settingsForm
            case .exporting(let progress): progressView(progress)
            case .done(let url): doneView(url)
            case .failed(let message): failedView(message)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            name = model.project.name
            frameRate = model.project.settings.frameRate
            let short = min(model.project.settings.width, model.project.settings.height)
            resolution = ExportResolution.allCases.last { $0 != .project && $0.rawValue <= short } ?? .p1080
        }
    }

    // MARK: - Réglages

    private var settingsForm: some View {
        let output = ExportSettings.outputSize(project: model.project.settings, resolution: resolution)
        let bytes = settings.estimatedBytes(project: model.project.settings, duration: exportDuration)
        return VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $kind) {
                ForEach(ExportKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                TextField("Nom du fichier", text: $name)
                LabeledContent("Dossier") {
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choisir…") { chooseFolder() }
                    }
                }
                if model.inPoint != nil || model.outPoint != nil {
                    Toggle("Seulement la plage entre les points d'entrée et de sortie (\(rangeLabel))", isOn: $onlyRange)
                        .disabled(kind == .still)
                }
                if kind == .video && !model.project.subtitleClips.isEmpty {
                    Toggle("Créer aussi le fichier de sous-titres (.srt)", isOn: $withSubtitles)
                }
                if kind == .video { videoFields }
                if kind == .gif { LabeledContent("GIF", value: "640 px de large au plus, 15 images/s, en boucle") }
                if kind == .still { LabeledContent("Image", value: "Image à la tête de lecture (\(model.playhead.timecode(fps: model.fps))), à la résolution choisie") }
                if kind == .still {
                    Picker("Résolution", selection: $resolution) {
                        ForEach(ExportResolution.allCases) { r in
                            let size = ExportSettings.outputSize(project: model.project.settings, resolution: r)
                            Text("\(r.label) — \(Int(size.width))×\(Int(size.height))").tag(r)
                        }
                    }
                }
                if kind == .audio { LabeledContent("Son", value: "AAC 256 kb/s, mixé comme dans la vidéo") }
            }
            .formStyle(.grouped)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if kind == .video {
                        Text("\(Int(output.width))×\(Int(output.height)) · \(frameRate) i/s · durée \(exportDuration.shortLabel)")
                        Text("Taille estimée : \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Durée \(exportDuration.shortLabel)")
                    }
                }
                .font(.callout)
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("En arrière-plan") { startInBackground() }
                    .help("L'export continue pendant que vous montez ; une notification signale la fin.")
                    .disabled(model.project.duration == .zero)
                Button("Exporter") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.project.duration == .zero)
            }
            if model.project.duration == .zero {
                Text("La timeline est vide : ajoutez au moins un clip avant d'exporter.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var rangeLabel: String {
        "\((model.inPoint ?? .zero).timecode(fps: model.fps)) → \((model.outPoint ?? model.project.duration).timecode(fps: model.fps))"
    }

    private var exportDuration: RTime {
        guard onlyRange else { return model.project.duration }
        return (model.outPoint ?? model.project.duration) - (model.inPoint ?? .zero)
    }

    @ViewBuilder private var videoFields: some View {
                Picker("Préréglage", selection: $preset) {
                    ForEach(Preset.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: preset) { _, p in apply(p) }
                Picker("Format", selection: $container) {
                    ForEach(ExportContainer.allCases) { Text($0.label).tag($0) }
                }
                .disabled(codec == .prores422)
                Picker("Codec", selection: $codec) {
                    ForEach(ExportCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Résolution", selection: $resolution) {
                    ForEach(ExportResolution.allCases) { r in
                        let size = ExportSettings.outputSize(project: model.project.settings, resolution: r)
                        Text("\(r.label) — \(Int(size.width))×\(Int(size.height))").tag(r)
                    }
                }
                Picker("Images par seconde", selection: $frameRate) {
                    ForEach(ProjectSettings.supportedFrameRates, id: \.self) { Text("\($0) i/s").tag($0) }
                }
                if codec != .prores422 {
                    Picker("Débit", selection: $bitrate) {
                        ForEach(BitrateChoice.allCases) { Text($0.label).tag($0) }
                    }
                    if bitrate == .custom {
                        LabeledContent("Débit vidéo") {
                            HStack {
                                TextField("", value: $customMbps, format: .number.precision(.fractionLength(0...1)))
                                    .frame(width: 70)
                                Text("Mb/s")
                            }
                        }
                    } else {
                        LabeledContent("Débit vidéo", value: String(format: "%.1f Mb/s", Double(settings.videoBitrate(project: model.project.settings)) / 1_000_000))
                    }
                }
    }

    private func apply(_ preset: Preset) {
        switch preset {
        case .custom: break
        case .youtube1080:
            container = .mp4; codec = .h264; resolution = .p1080; bitrate = .recommended
        case .youtube4k:
            container = .mp4; codec = .h264; resolution = .p2160; bitrate = .recommended
        case .social:
            container = .mp4; codec = .h264; resolution = .p1080; frameRate = 30; bitrate = .recommended
        case .web:
            container = .mp4; codec = .h264; resolution = .p720; bitrate = .custom; customMbps = 2.5
        case .archive:
            container = .mov; codec = .prores422; resolution = .project
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    // MARK: - Export

    /// Travail d'export selon le type choisi (exécuté ici ou dans la file d'arrière-plan).
    private func makeWork() -> (Exporter, @escaping @Sendable (Double) -> Void) async throws -> Void {
        let project = model.project
        let settings = self.settings
        let kind = self.kind
        let target = destination
        let at = model.playhead
        let still = ExportSettings.outputSize(project: project.settings, resolution: resolution)
        let subtitles = withSubtitles && kind == .video ? project.subtitleCues : []
        let start = settings.rangeStart, end = settings.rangeEnd
        return { exporter, progress in
            switch kind {
            case .video:
                try await exporter.run(project: project, settings: settings, progress: progress)
                if !subtitles.isEmpty {
                    let offset = start ?? .zero
                    let shifted = subtitles.compactMap { c -> SubtitleCue? in
                        guard c.end > offset, end.map({ c.start < $0 }) ?? true else { return nil }
                        return SubtitleCue(start: max(.zero, c.start - offset), end: c.end - offset, text: c.text)
                    }
                    try Subtitles.format(shifted, as: .srt).write(to: target.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                }
            case .gif:
                try await ExtraExporters.gif(project: project, destination: target, start: start, end: end, progress: progress)
            case .audio:
                progress(0.1)
                try await ExtraExporters.audio(project: project, destination: target, start: start, end: end)
                progress(1)
            case .still:
                try await ExtraExporters.still(project: project, at: at, size: still, destination: target)
                progress(1)
            }
        }
    }

    private func confirmOverwrite(_ target: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return true }
        let alert = NSAlert()
        alert.messageText = "« \(target.lastPathComponent) » existe déjà"
        alert.informativeText = "Voulez-vous le remplacer ?"
        alert.addButton(withTitle: "Remplacer")
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func startInBackground() {
        let target = destination
        guard confirmOverwrite(target) else { return }
        ExportQueue.shared.add(name: target.lastPathComponent, destination: target, work: makeWork())
        dismiss()
    }

    private func start() {
        let target = destination
        guard confirmOverwrite(target) else { return }
        model.playback.pause()
        let exporter = Exporter()
        self.exporter = exporter
        let work = makeWork()
        phase = .exporting(0)
        requestNotificationPermission()
        task = Task {
            do {
                try await work(exporter) { value in
                    Task { @MainActor in
                        if case .exporting = phase { phase = .exporting(value) }
                    }
                }
                phase = .done(target)
                notify(title: "Export terminé", body: target.lastPathComponent)
            } catch is CancellationError {
                phase = .settings
            } catch {
                Log.error("Export : \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func progressView(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress)
            Text("\(Int(progress * 100)) % — vous pouvez continuer à regarder votre projet, l'export se fait en arrière-plan de cette fenêtre.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler l'export") {
                    exporter?.cancel()
                    task?.cancel()
                }
            }
        }
    }

    private func doneView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("La vidéo est prête.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(url.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Ouvrir") { NSWorkspace.shared.open(url) }
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("L'export n'a pas abouti", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text(message).font(.callout).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Modifier les réglages") { phase = .settings }
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
