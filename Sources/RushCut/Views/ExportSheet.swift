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

    private var settings: ExportSettings {
        var s = ExportSettings(destination: destination)
        s.container = codec == .prores422 ? .mov : container
        s.codec = codec
        s.resolution = resolution
        s.frameRate = frameRate
        s.bitrateChoice = bitrate
        s.customMbps = customMbps
        return s
    }

    private var destination: URL {
        let ext = codec == .prores422 ? "mov" : container.rawValue
        let clean = ProjectStore.sanitize(name.isEmpty ? model.project.name : name)
        return folder.appendingPathComponent(clean).appendingPathExtension(ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporter la vidéo").font(.title2.weight(.semibold))
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
        let bytes = settings.estimatedBytes(project: model.project.settings, duration: model.project.duration)
        return VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Nom du fichier", text: $name)
                LabeledContent("Dossier") {
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choisir…") { chooseFolder() }
                    }
                }
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
            .formStyle(.grouped)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(output.width))×\(Int(output.height)) · \(frameRate) i/s · durée \(model.project.duration.shortLabel)")
                    Text("Taille estimée : \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
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

    private func start() {
        let target = destination
        if FileManager.default.fileExists(atPath: target.path) {
            let alert = NSAlert()
            alert.messageText = "« \(target.lastPathComponent) » existe déjà"
            alert.informativeText = "Voulez-vous le remplacer ?"
            alert.addButton(withTitle: "Remplacer")
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.playback.pause()
        let exporter = Exporter()
        self.exporter = exporter
        let project = model.project
        let settings = self.settings
        phase = .exporting(0)
        requestNotificationPermission()
        task = Task {
            do {
                try await exporter.run(project: project, settings: settings) { value in
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
