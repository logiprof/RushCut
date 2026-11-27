import SwiftUI
import AppKit

/// Bandeau d'état des outils longs (suivi, inversion, conversion…) et messages brefs.
struct ToolStatusBanner: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var queue = ExportQueue.shared
    @State private var showQueue = false

    var body: some View {
        HStack(spacing: 10) {
            if let status = model.toolStatus {
                ProgressView().controlSize(.small)
                Text(status).font(.callout)
            } else if let message = model.toolMessage {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.callout)
            }
            if !queue.jobs.isEmpty {
                Button { showQueue.toggle() } label: {
                    HStack(spacing: 6) {
                        if let p = queue.overallProgress { ProgressView(value: p).frame(width: 60) }
                        Text(queue.activeCount > 0 ? "\(queue.activeCount) export(s) en cours" : "Exports terminés")
                    }
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showQueue) { ExportQueueView(queue: queue) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .opacity(model.toolStatus != nil || model.toolMessage != nil || !queue.jobs.isEmpty ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: model.toolStatus)
        .animation(.easeInOut(duration: 0.2), value: model.toolMessage)
    }
}

struct ExportQueueView: View {
    @ObservedObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exports").font(.headline)
            ForEach(queue.jobs) { job in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name).font(.callout.weight(.medium))
                        switch job.state {
                        case .waiting: Text("En attente").font(.caption).foregroundStyle(.secondary)
                        case .running(let p): ProgressView(value: p)
                        case .done: Text("Terminé").font(.caption).foregroundStyle(.green)
                        case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
                        case .cancelled: Text("Annulé").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    switch job.state {
                    case .done:
                        Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }
                    case .waiting, .running:
                        Button("Annuler") { queue.cancel(job.id) }
                    default:
                        EmptyView()
                    }
                }
                .controlSize(.small)
            }
            Divider()
            Button("Effacer les exports terminés") { queue.clearFinished() }
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// Historique des versions enregistrées automatiquement (20 au maximum).
struct VersionsSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [ProjectStore.SavedVersion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Historique des versions").font(.title2.weight(.semibold))
            Text("RushCut garde une copie du projet au plus toutes les 5 minutes pendant que vous travaillez (les 20 dernières). Restaurer une version est annulable avec ⌘Z.")
                .font(.callout).foregroundStyle(.secondary)
            if versions.isEmpty {
                Text("Aucune version enregistrée pour l'instant.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                List(versions) { v in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(v.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Button("Restaurer") {
                            model.restoreVersion(v)
                            dismiss()
                        }
                    }
                }
                .frame(height: 300)
            }
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { versions = ProjectStore.versions(of: model.url) }
    }
}

/// Installation du module de conversion (FFmpeg) et conversion des fichiers en attente.
struct FFmpegSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var working = false
    @State private var installed = FFmpegModule.isInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Module de conversion").font(.title2.weight(.semibold))
            if !model.pendingConversion.isEmpty {
                Text("Ces fichiers ne sont pas lus directement par macOS :").font(.callout)
                ForEach(model.pendingConversion, id: \.self) { Text("• \($0.lastPathComponent)").font(.callout).foregroundStyle(.secondary) }
            }
            Text(installed
                 ? "FFmpeg est installé. Les formats WebM, MKV, AVI, FLV, WMV, OGG, Opus… sont convertis en MP4 ou M4A puis importés."
                 : "RushCut peut télécharger FFmpeg (logiciel libre, environ 40 Mo, une seule fois) pour convertir les formats WebM, MKV, AVI, FLV, WMV, OGG, Opus… Les fichiers convertis sont rangés dans le dossier du projet.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Fermer") {
                    model.pendingConversion = []
                    dismiss()
                }
                Spacer()
                if !installed {
                    Button("Télécharger et installer") { install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                } else if !model.pendingConversion.isEmpty {
                    Button("Convertir et importer") {
                        let files = model.pendingConversion
                        model.pendingConversion = []
                        dismiss()
                        model.convertAndImport(files)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if working { ProgressView().controlSize(.small) }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func install() {
        working = true
        Task {
            do {
                try await FFmpegModule.install { message in Task { @MainActor in status = message } }
                installed = true
            } catch {
                status = "Installation impossible : \(error.localizedDescription)"
            }
            working = false
        }
    }
}

/// Enregistrement de l'écran.
struct ScreenRecordSheet: View {
    @ObservedObject var model: EditorModel
    @StateObject private var recorder = ScreenRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var display: CGDirectDisplayID = 0
    @State private var systemAudio = true
    @State private var microphone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enregistrer l'écran").font(.title2.weight(.semibold))
            if recorder.isRecording {
                HStack {
                    Circle().fill(.red).frame(width: 12, height: 12)
                    Text(String(format: "Enregistrement… %d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60))
                        .font(.title3.monospacedDigit())
                }
                Text("La fenêtre de RushCut n'apparaît pas dans l'enregistrement.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Écran", selection: $display) {
                    ForEach(recorder.displays) { Text($0.name).tag($0.id) }
                }
                Toggle("Son du Mac", isOn: $systemAudio)
                Toggle("Micro", isOn: $microphone)
                Text("La vidéo est placée à la tête de lecture quand vous arrêtez l'enregistrement.").font(.callout).foregroundStyle(.secondary)
            }
            if let error = recorder.errorMessage { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Fermer") { dismiss() }.disabled(recorder.isRecording)
                Spacer()
                if recorder.isRecording {
                    Button("Arrêter") {
                        Task {
                            let at = model.playhead
                            if let url = await recorder.stop(), let id = await model.importMedia([url]).first {
                                model.dropMedia(id, at: at, target: nil)
                            }
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Démarrer") {
                        Task { await recorder.start(displayID: display, systemAudio: systemAudio, microphone: microphone, folder: model.generatedMediaFolder) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.displays.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            await recorder.loadDisplays()
            if display == 0, let first = recorder.displays.first { display = first.id }
        }
    }
}

/// Outils d'un clip, dans l'inspecteur (onglet Image).
struct ClipToolsSection: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    @State private var focusX = 0.0
    @State private var focusY = 0.0
    @State private var factor = 2.0
    @State private var hold = 1.5

    var body: some View {
        let media = model.project.media(clip.mediaID)
        let isVideo = media?.kind == .video
        InspectorSection(title: "Outils") {
            VStack(alignment: .leading, spacing: 6) {
                if media?.hasAudio == true || media?.kind == .audio {
                    Button { model.removeSilences(clip.id) } label: { Label("Supprimer les silences", systemImage: "waveform.path.badge.minus") }
                }
                if isVideo {
                    Button { model.freezeFrame(clip.id) } label: { Label("Image figée (3 s)", systemImage: "pause.rectangle") }
                    Button { model.reverseClip(clip.id) } label: { Label("Lire à l'envers", systemImage: "backward") }
                }
                if clip.mediaID != nil {
                    Button { model.replaceClipPanel(clip.id) } label: { Label("Remplacer le clip…", systemImage: "arrow.triangle.2.circlepath") }
                }
                if clip.isText || clip.isSticker || media?.kind == .image {
                    Button { model.trackMotion(clip.id) } label: { Label("Suivre le mouvement de la vidéo dessous", systemImage: "scope") }
                        .help("Placez le calque sur l'objet à suivre, la tête de lecture au début du suivi.")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.toolStatus != nil)
            if clip.mediaID != nil || clip.isText || clip.isSticker {
                Divider()
                Text("Zoom sur une zone").font(.caption.weight(.semibold))
                SliderField(title: "Centre X", value: focusX * 100, range: -50...50, unit: "%") { focusX = $0 / 100 }
                SliderField(title: "Centre Y", value: focusY * 100, range: -50...50, unit: "%") { focusY = $0 / 100 }
                SliderField(title: "Grossissement", value: factor, range: 1.2...5, unit: "×", fractionDigits: 1) { factor = $0 }
                SliderField(title: "Maintien", value: hold, range: 0.2...10, unit: "s", fractionDigits: 1) { hold = $0 }
                Button("Zoomer à la tête de lecture") { model.addZoom(clip.id, focusX: focusX, focusY: focusY, factor: factor, hold: hold) }
                    .controlSize(.small)
                    .disabled(model.localTime(in: clip) == nil)
            }
        }
    }
}
