import SwiftUI
import AVFoundation

/// Écoute d'un son de la bibliothèque avant de l'ajouter.
@MainActor
final class SoundPreview: ObservableObject {
    @Published private(set) var playingID: String?
    @Published private(set) var loadingIDs: Set<String> = []
    private var player: AVAudioPlayer?

    func toggle(_ def: SoundDef) {
        if playingID == def.id { stop(); return }
        loadingIDs.insert(def.id)
        Task {
            defer { loadingIDs.remove(def.id) }
            guard let url = try? await SoundLibrary.file(for: def), let p = try? AVAudioPlayer(contentsOf: url) else { return }
            player?.stop()
            player = p
            p.play()
            playingID = def.id
            let id = def.id
            DispatchQueue.main.asyncAfter(deadline: .now() + min(def.seconds + 0.5, 20)) { [weak self] in
                if self?.playingID == id { self?.stop() }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}

struct AudioLibrary: View {
    @ObservedObject var model: EditorModel
    @StateObject private var preview = SoundPreview()
    @State private var kind: SoundDef.Kind = .music
    @State private var adding: String?
    @State private var voiceOver = false

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $kind) {
                Text("Musique").tag(SoundDef.Kind.music)
                Text("Effets sonores").tag(SoundDef.Kind.effect)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            HStack {
                Button { voiceOver = true } label: { Label("Voix off", systemImage: "mic.fill") }
                Button { model.importPanel() } label: { Label("Importer…", systemImage: "square.and.arrow.down") }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            Text("Sons originaux créés par RushCut : libres de droits, utilisables dans toutes vos vidéos, même monétisées.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(SoundLibrary.all.filter { $0.kind == kind }) { def in
                        row(def)
                    }
                }
                .padding(10)
            }
        }
        .padding(.top, 8)
        .onDisappear { preview.stop() }
        .sheet(isPresented: $voiceOver) { VoiceOverSheet(model: model) }
    }

    private func row(_ def: SoundDef) -> some View {
        HStack(spacing: 8) {
            Button { preview.toggle(def) } label: {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    if preview.loadingIDs.contains(def.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: preview.playingID == def.id ? "stop.fill" : "play.fill").font(.system(size: 11))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Écouter")
            VStack(alignment: .leading, spacing: 1) {
                Text(def.name).font(.system(size: 12, weight: .medium))
                Text(def.bpm.map { "\(def.mood) · \($0) bpm" } ?? def.mood).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%d:%02d", Int(def.seconds) / 60, Int(def.seconds.rounded(.up)) % 60))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                adding = def.id
                Task {
                    await model.addSound(def)
                    adding = nil
                }
            } label: {
                if adding == def.id { ProgressView().controlSize(.mini) } else { Image(systemName: "plus.circle.fill").font(.system(size: 16)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Ajouter à la tête de lecture")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(preview.playingID == def.id ? 0.08 : 0.03)))
    }
}

/// Enregistrement d'une voix off pendant que la vidéo défile.
struct VoiceOverSheet: View {
    @ObservedObject var model: EditorModel
    @StateObject private var recorder = VoiceRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var startTime: RTime = .zero
    @State private var countdown: Int?
    @State private var playAlong = true

    var body: some View {
        VStack(spacing: 16) {
            Text("Voix off").font(.title2.weight(.semibold))
            Text("L'enregistrement commence à la tête de lecture (\(model.playhead.timecode(fps: model.fps))). Utilisez un casque pour que le son de la vidéo ne soit pas enregistré.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            ZStack {
                Circle().fill(recorder.isRecording ? Color.red.opacity(0.2) : Color.white.opacity(0.06))
                    .frame(width: 120, height: 120)
                    .scaleEffect(1 + CGFloat(min(Float(1), recorder.level * 4)) * 0.25)
                    .animation(.easeOut(duration: 0.08), value: recorder.level)
                if let countdown {
                    Text("\(countdown)").font(.system(size: 48, weight: .bold))
                } else {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(recorder.isRecording ? .red : .primary)
                }
            }
            .onTapGesture { recorder.isRecording ? finish() : begin() }
            Text(recorder.isRecording ? String(format: "%.1f s", recorder.elapsed) : "Cliquez sur le micro pour commencer")
                .font(.callout.monospacedDigit())
            Toggle("Lire la vidéo pendant l'enregistrement", isOn: $playAlong)
                .disabled(recorder.isRecording)
            if let error = recorder.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 380)
            }
            HStack {
                Button("Annuler") {
                    recorder.cancel()
                    model.playback.pause()
                    dismiss()
                }
                Spacer()
                Button(recorder.isRecording ? "Terminer" : "Enregistrer") { recorder.isRecording ? finish() : begin() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func begin() {
        guard countdown == nil else { return }
        startTime = model.playhead
        countdown = 3
        Task {
            for n in [2, 1] {
                try? await Task.sleep(for: .seconds(1))
                countdown = n
            }
            try? await Task.sleep(for: .seconds(1))
            countdown = nil
            await recorder.start(in: model.generatedMediaFolder)
            if recorder.isRecording && playAlong { model.playback.play() }
        }
    }

    private func finish() {
        model.playback.pause()
        guard let file = recorder.stop() else { return }
        let at = startTime
        Task {
            await model.placeVoiceOver(file, at: at)
            dismiss()
        }
    }
}

/// Vu-mètre stéréo (niveaux de sortie de la lecture).
struct LevelMeter: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let (l, r) = AudioMeter.shared.levels()
            HStack(spacing: 2) {
                bar(l)
                bar(r)
            }
            .frame(width: 12, height: 26)
            .help("Niveau du son (rouge : saturation)")
        }
    }

    private func bar(_ value: Float) -> some View {
        GeometryReader { g in
            let db: Float = 20 * log10(max(value, 1e-4))
            let clamped: Float = max(0, min(1, (db + 48) / 48))
            let fraction = CGFloat(clamped)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.08))
                LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top)
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * fraction) }
            }
        }
    }
}
