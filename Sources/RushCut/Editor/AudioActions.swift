import Foundation
import AVFoundation

/// Actions audio du lot V1 : sons intégrés, normalisation, extraction, voix off.
extension EditorModel {
    /// Dossier des médias créés par RushCut (dans le paquet du projet).
    var generatedMediaFolder: URL { AppPaths.ensure(url.appendingPathComponent("Médias", isDirectory: true)) }

    /// Ajoute un son de la bibliothèque à la tête de lecture.
    func addSound(_ def: SoundDef) async {
        do {
            let file = try await SoundLibrary.file(for: def)
            guard let id = await importMedia([file]).first else { return }
            apply("Renommer le son") { p in
                if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].name = def.name }
            }
            dropMedia(id, at: playhead, target: nil)
        } catch {
            AppModel.shared.alert = AppAlert(title: "Son indisponible", message: error.localizedDescription)
        }
    }

    /// Règle le volume pour atteindre une sonie cible (−14 LUFS pour les réseaux sociaux).
    func normalizeLoudness(_ clipIDs: [UUID], target: Double = -14) {
        let jobs: [(UUID, URL, Double, Double)] = clipIDs.compactMap { id in
            guard let clip = project.clip(id), let media = project.media(clip.mediaID), media.hasAudio || media.kind == .audio,
                  let url = MediaResolver.url(for: media) else { return nil }
            return (id, url, clip.sourceIn.seconds, clip.duration.seconds * clip.speed.rate)
        }
        guard !jobs.isEmpty else { return }
        Task {
            var results: [(UUID, Double)] = []
            for (id, url, start, duration) in jobs {
                if let lufs = await Loudness.integrated(url: url, start: start, duration: duration) {
                    results.append((id, max(-30, min(20, target - lufs))))
                }
            }
            guard !results.isEmpty else {
                AppModel.shared.alert = AppAlert(title: "Normalisation impossible", message: "Le son sélectionné est silencieux ou illisible.")
                return
            }
            apply("Normaliser le volume") { p in
                for (id, db) in results {
                    p.updateClip(id) { c in
                        c.audio.volumeDB = (db * 10).rounded() / 10
                        c.keyframes[KeyProp.volume.rawValue] = nil
                    }
                }
            }
        }
    }

    /// Crée un fichier audio (.m4a) à partir du son d'une vidéo et l'ajoute aux médias.
    func extractAudio(mediaID: UUID) {
        guard let media = project.media(mediaID), media.kind == .video, media.hasAudio, let source = MediaResolver.url(for: media) else { return }
        let base = (media.name as NSString).deletingPathExtension
        var output = generatedMediaFolder.appendingPathComponent("\(base) (son).m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = generatedMediaFolder.appendingPathComponent("\(base) (son \(n)).m4a")
            n += 1
        }
        let target = output
        Task {
            do {
                let asset = AVURLAsset(url: source)
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw RushError.exportFailed("l'extraction du son n'est pas disponible pour ce fichier.")
                }
                try await session.export(to: target, as: .m4a)
                await importMedia([target])
            } catch {
                AppModel.shared.alert = AppAlert(title: "Extraction du son impossible", message: error.localizedDescription)
            }
        }
    }

    /// Enregistrement de voix off terminé : le fichier est placé à l'instant où l'enregistrement a commencé.
    func placeVoiceOver(_ file: URL, at time: RTime) async {
        guard let id = await importMedia([file]).first else { return }
        apply("Renommer la voix off") { p in
            if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].name = "Voix off \(p.media.filter { $0.name.hasPrefix("Voix off") }.count + 1)" }
        }
        dropMedia(id, at: time, target: .newTrack)
    }
}

/// Enregistreur de voix off (micro du Mac), en AAC.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: Double = 0
    @Published var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(in folder: URL) async {
        guard await requestAccess() else {
            errorMessage = "RushCut n'a pas accès au micro. Autorisez-le dans Réglages Système › Confidentialité et sécurité › Micro."
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("Voix off \(stamp).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.record() else { throw RushError.exportFailed("le micro n'a pas démarré.") }
            recorder = r
            fileURL = url
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    r.updateMeters()
                    self.level = pow(10, r.averagePower(forChannel: 0) / 20)
                    self.elapsed = r.currentTime
                }
            }
        } catch {
            errorMessage = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    /// Arrête et renvoie le fichier (nil si rien n'a été enregistré).
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        guard let fileURL, elapsed > 0.2 else { return nil }
        return fileURL
    }

    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }
}
