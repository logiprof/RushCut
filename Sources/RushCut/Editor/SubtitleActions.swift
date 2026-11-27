import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Sous-titres automatiques, import/export SRT et VTT, voix de synthèse, voix externes.
extension EditorModel {
    func generateSubtitles(language: String) {
        guard !subtitleBusy else { return }
        subtitleBusy = true
        subtitleStatus = "Préparation du son…"
        let snapshot = project
        Task {
            defer { subtitleBusy = false }
            do {
                let audio = try await Transcriber.renderProjectAudio(snapshot)
                defer { try? FileManager.default.removeItem(at: audio) }
                let words = try await Transcriber.transcribe(file: audio, language: language) { message in
                    Task { @MainActor in self.subtitleStatus = message }
                }
                let cues = Subtitles.group(words)
                apply("Sous-titres automatiques") { $0.setSubtitles(cues) }
                subtitleStatus = "\(cues.count) lignes de sous-titres créées (\(words.count) mots)."
            } catch {
                subtitleStatus = nil
                AppModel.shared.alert = AppAlert(title: "Sous-titres automatiques impossibles", message: error.localizedDescription)
            }
        }
    }

    func importSubtitlesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Importer des sous-titres"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let cues = Subtitles.parse(text)
            guard !cues.isEmpty else {
                AppModel.shared.alert = AppAlert(title: "Fichier vide", message: "Aucun sous-titre n'a été trouvé dans « \(url.lastPathComponent) ».")
                return
            }
            apply("Importer des sous-titres") { $0.setSubtitles(cues) }
            subtitleStatus = "\(cues.count) sous-titres importés."
        } catch {
            AppModel.shared.alert = AppAlert(title: "Import impossible", message: error.localizedDescription)
        }
    }

    func exportSubtitlesPanel(_ format: SubtitleFormat) {
        let cues = project.subtitleCues
        guard !cues.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Exporter les sous-titres"
        panel.nameFieldStringValue = "\(project.name).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Subtitles.format(cues, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppModel.shared.alert = AppAlert(title: "Export impossible", message: error.localizedDescription)
        }
    }

    /// Applique le style du texte sélectionné à tous les sous-titres (le texte de chacun est conservé).
    func applyStyleToAllSubtitles(from clip: Clip) {
        guard let style = clip.text else { return }
        let ids = project.subtitleClips.map(\.id)
        let transform = clip.transform
        apply("Style de tous les sous-titres") { p in
            for id in ids {
                p.updateClip(id) { c in
                    guard var t = c.text else { return }
                    let string = t.string, words = t.words
                    t = style
                    t.string = string
                    t.words = words
                    t.isSubtitle = true
                    c.text = t
                    c.transform = transform
                }
            }
        }
    }

    func updateSubtitleText(_ id: UUID, _ text: String) {
        updateClip(id, "Modifier le sous-titre", coalesce: "st-\(id)") { c in
            if c.text?.string != text {
                c.text?.string = text
                c.text?.words = []
                c.name = String(text.prefix(30))
            }
        }
    }

    /// Lit un texte avec une voix de synthèse et place le son sous le texte.
    func speak(_ clipID: UUID, voiceID: String?, rate: Float) {
        guard let clip = project.clip(clipID), let text = clip.text?.string, !text.isEmpty else { return }
        let start = clip.start
        let file = generatedMediaFolder.appendingPathComponent("Voix de synthèse \(UUID().uuidString.prefix(6)).caf")
        subtitleBusy = true
        Task {
            defer { subtitleBusy = false }
            do {
                try await SpeechSynth.render(text, voiceID: voiceID, rate: rate, to: file)
                guard let id = await importMedia([file]).first else { return }
                apply("Renommer la voix") { p in
                    if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].name = "Voix : \(String(text.prefix(24)))" }
                }
                dropMedia(id, at: start, target: .newTrack)
            } catch {
                AppModel.shared.alert = AppAlert(title: "Voix de synthèse impossible", message: error.localizedDescription)
            }
        }
    }

    /// Importe plusieurs voix (fichiers audio) d'un coup : alignées sur les textes à partir de la tête de lecture
    /// s'il y en a assez, sinon placées l'une après l'autre.
    func batchImportVoicesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Importer des voix"
        panel.message = "Les fichiers sont placés dans l'ordre de leur nom."
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let from = playhead
        Task {
            let ids = await importMedia(urls)
            guard !ids.isEmpty else { return }
            let texts = project.tracks.filter { $0.kind == .text }.flatMap(\.clips).filter { $0.start >= from }.sorted { $0.start < $1.start }
            let align = texts.count >= ids.count
            apply("Importer des voix") { p in
                var t = from
                var track = Track(kind: .audio)
                for (i, id) in ids.enumerated() {
                    guard let media = p.media(id) else { continue }
                    var clip = Clip()
                    clip.mediaID = id
                    clip.name = media.name
                    clip.duration = media.duration
                    clip.start = (align ? texts[i].start : t).snapped(fps: p.settings.frameRate)
                    if let last = track.clips.last, clip.start < last.end { clip.start = last.end }
                    track.clips.append(clip)
                    t = clip.end + RTime(seconds: 0.25)
                }
                p.tracks.append(track)
            }
            subtitleStatus = align ? "\(ids.count) voix alignées sur les textes." : "\(ids.count) voix placées à la suite."
        }
    }
}
