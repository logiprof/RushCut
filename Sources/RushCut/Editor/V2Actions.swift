import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Fonctions du lot V2 : détourage, recadrage automatique, stabilisation, ralenti fluide, plans, temps forts,
/// mots parasites, montage par le texte, LUT, groupes, clips composés, modèles et charte graphique.
extension EditorModel {
    private func status(_ s: String?) { toolStatus = s }

    private struct VideoSource {
        let clip: Clip
        let media: MediaRef
        let url: URL
    }

    private func videoSource(_ clipID: UUID) -> VideoSource? {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID), media.kind == .video,
              let url = MediaResolver.url(for: media) else { return nil }
        return VideoSource(clip: clip, media: media, url: url)
    }

    /// Instant de la timeline correspondant à un instant de la source du clip.
    private func timelineLocal(_ clip: Clip, source: Double) -> RTime {
        RTime(seconds: (source - clip.sourceIn.seconds) / max(0.01, clip.speed.rate))
    }

    // MARK: Recadrage automatique

    func autoReframe(_ clipID: UUID) {
        guard let src = videoSource(clipID) else { return }
        let clip = src.clip, media = src.media, url = src.url
        let canvas = project.settings.canvasSize
        let videoAspect = media.pixelSize.width / max(media.pixelSize.height, 1)
        let canvasAspect = canvas.width / max(canvas.height, 1)
        guard videoAspect > canvasAspect * 1.05 else {
            toolMessage = "La vidéo n'est pas plus large que le cadre : rien à recadrer."
            return
        }
        status("Recherche du sujet…")
        Task {
            defer { status(nil) }
            do {
                let path = try await Reframer.subjectPath(url: url, start: clip.sourceIn.seconds, duration: clip.sourceLength.seconds)
                let layerWidth = canvas.height * videoAspect
                let maxOffset = (layerWidth - canvas.width) / 2 / canvas.width
                let fps = project.settings.frameRate
                apply("Recadrage automatique") { p in
                    p.updateClip(clipID) { c in
                        c.fit = .fill
                        c.transform.scale = 1
                        var keys: [Keyframe] = []
                        for (t, u) in path {
                            let local = self.timelineLocal(c, source: t).snapped(fps: fps)
                            guard local >= .zero, local <= c.duration else { continue }
                            let x = max(-maxOffset, min(maxOffset, -(u - 0.5) * layerWidth / canvas.width))
                            keys.append(Keyframe(time: local, value: x, interpolation: .douce))
                        }
                        c.keyframes[KeyProp.positionX.rawValue] = keys.isEmpty ? nil : keys
                    }
                }
            } catch {
                AppModel.shared.alert = AppAlert(title: "Recadrage impossible", message: error.localizedDescription)
            }
        }
    }

    /// Passe le projet en vertical 9:16 et recadre toutes les vidéos de la piste principale sur leur sujet.
    func convertToVertical() {
        updateSettings("Passer en 9:16") { s in
            let short = min(s.width, s.height)
            s.width = short
            s.height = Int((Double(short) * 16 / 9 / 2).rounded()) * 2
        }
        guard let mi = project.mainTrackIndex else { return }
        for clip in project.tracks[mi].clips where project.media(clip.mediaID)?.kind == .video { autoReframe(clip.id) }
    }

    // MARK: Stabilisation

    func stabilize(_ clipID: UUID, strength: Double = 0.6) {
        guard let src = videoSource(clipID) else { return }
        let clip = src.clip, media = src.media, url = src.url
        status("Stabilisation…")
        Task {
            defer { status(nil) }
            do {
                let corrections = try await Stabilizer.corrections(url: url, start: clip.sourceIn.seconds, duration: min(clip.sourceLength.seconds, 180), strength: strength)
                guard !corrections.isEmpty else { return }
                let canvas = project.settings.canvasSize
                let zoom = 1.08 + 0.06 * strength
                let geometry = Geometry.layer(sourceSize: media.pixelSize, canvas: canvas, fit: clip.fit, transform: Transform())
                let lw = geometry.size.width / canvas.width * zoom, lh = geometry.size.height / canvas.height * zoom
                let fps = project.settings.frameRate
                apply("Stabiliser") { p in
                    p.updateClip(clipID) { c in
                        c.transform.scale = c.transform.scale * zoom
                        var xs: [Keyframe] = [], ys: [Keyframe] = []
                        let bx = c.transform.positionX, by = c.transform.positionY
                        for (i, (t, dx, dy)) in corrections.enumerated() where i % 2 == 0 {
                            let local = self.timelineLocal(c, source: t).snapped(fps: fps)
                            guard local >= .zero, local <= c.duration else { continue }
                            xs.append(Keyframe(time: local, value: bx + dx * lw, interpolation: .lineaire))
                            ys.append(Keyframe(time: local, value: by + dy * lh, interpolation: .lineaire))
                        }
                        c.keyframes[KeyProp.positionX.rawValue] = xs
                        c.keyframes[KeyProp.positionY.rawValue] = ys
                    }
                }
                toolMessage = "Vidéo stabilisée (zoom de \(Int((zoom - 1) * 100)) % pour cacher les bords)."
            } catch {
                AppModel.shared.alert = AppAlert(title: "Stabilisation impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Ralenti fluide

    func smoothSlowMotion(_ clipID: UUID) {
        guard let src = videoSource(clipID), src.clip.speed.rate < 0.99, src.clip.speed.curve.isEmpty else {
            toolMessage = "Choisissez d'abord une vitesse inférieure à ×1 dans l'onglet Vitesse."
            return
        }
        let clip = src.clip, media = src.media, url = src.url
        let out = generatedMediaFolder.appendingPathComponent("\((media.name as NSString).deletingPathExtension) (ralenti \(Int(Date().timeIntervalSince1970))).mov")
        let fps = Double(project.settings.frameRate)
        status("Ralenti fluide…")
        Task {
            defer { status(nil) }
            do {
                try await SlowMotionRenderer.render(source: url, start: clip.sourceIn.seconds, duration: clip.sourceLength.seconds,
                                                    rate: clip.speed.rate, fps: fps, to: out) { p in
                    Task { @MainActor in self.toolStatus = "Ralenti fluide… \(Int(p * 100)) %" }
                }
                guard let id = await importMedia([out]).first else { return }
                apply("Ralenti fluide") { p in
                    p.updateClip(clipID) { c in
                        c.mediaID = id
                        c.sourceIn = .zero
                        c.speed = SpeedCurve()
                        c.name = "\(c.name) (ralenti fluide)"
                        c.audio.isMuted = true
                    }
                }
            } catch {
                AppModel.shared.alert = AppAlert(title: "Ralenti impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Changements de plan, temps forts

    func splitAtSceneChanges(_ clipID: UUID) {
        guard let src = videoSource(clipID) else { return }
        let clip = src.clip, url = src.url
        status("Recherche des changements de plan…")
        Task {
            defer { status(nil) }
            do {
                let cuts = try await SceneDetector.cuts(url: url, start: clip.sourceIn.seconds, duration: clip.sourceLength.seconds)
                let times = cuts.map { clip.start + timelineLocal(clip, source: $0) }.filter { $0 > clip.start && $0 < clip.end }
                guard !times.isEmpty else { toolMessage = "Aucun changement de plan trouvé."; return }
                apply("Couper aux changements de plan") { p in
                    var ids: Set<UUID> = [clipID]
                    for t in times {
                        let created = p.split(at: t, clipIDs: ids)
                        ids.formUnion(created)
                    }
                }
                toolMessage = "\(times.count) changements de plan : clip coupé en \(times.count + 1)."
            } catch {
                AppModel.shared.alert = AppAlert(title: "Analyse impossible", message: error.localizedDescription)
            }
        }
    }

    func markBeats(_ clipID: UUID) {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID), media.hasAudio || media.kind == .audio,
              let url = MediaResolver.url(for: media) else { return }
        status("Recherche des temps forts…")
        Task {
            defer { status(nil) }
            do {
                let (bpm, beats) = try await BeatDetector.beats(url: url, start: clip.sourceIn.seconds, duration: clip.sourceLength.seconds)
                guard !beats.isEmpty else { toolMessage = "Aucun rythme net trouvé."; return }
                let times = beats.map { clip.start + timelineLocal(clip, source: $0) }.filter { $0 >= clip.start && $0 < clip.end }
                apply("Temps forts") { p in
                    for (i, t) in times.enumerated() {
                        p.markers.append(Marker(time: t.snapped(fps: p.settings.frameRate), name: i % 4 == 0 ? "Mesure" : "Temps",
                                                color: i % 4 == 0 ? RGBA(r: 1, g: 0.3, b: 0.4) : RGBA(r: 0.3, g: 0.8, b: 1)))
                    }
                }
                toolMessage = "\(times.count) temps marqués (≈ \(Int(bpm.rounded())) bpm)."
            } catch {
                AppModel.shared.alert = AppAlert(title: "Analyse impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Transcription d'un clip

    /// Mots prononcés dans un clip, minutés dans la timeline (relatifs au clip).
    func transcribeClip(_ clipID: UUID, language: String) async throws -> [WordTiming] {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID), media.hasAudio || media.kind == .audio,
              let url = MediaResolver.url(for: media) else { throw Transcriber.Failure.noAudio }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("rushcut-clip-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else { throw Transcriber.Failure.noAudio }
        session.timeRange = CMTimeRange(start: clip.sourceIn.cmTime, duration: clip.sourceLength.cmTime)
        try await session.export(to: temp, as: .m4a)
        let words = try await Transcriber.transcribe(file: temp, language: language) { m in Task { @MainActor in self.toolStatus = m } }
        let rate = max(0.01, clip.speed.rate)
        return words.map { WordTiming(text: $0.text, start: RTime(seconds: $0.start.seconds / rate), end: RTime(seconds: $0.end.seconds / rate)) }
    }

    static let fillerWords: Set<String> = ["euh", "heu", "euuh", "hum", "hmm", "bah", "ben", "beh", "um", "uh", "erm", "äh", "ähm", "ehm", "mmh"]

    func removeFillerWords(_ clipID: UUID, language: String) {
        status("Recherche des mots parasites…")
        Task {
            defer { status(nil) }
            do {
                let words = try await transcribeClip(clipID, language: language)
                let fillers = words.filter { EditorModel.fillerWords.contains($0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
                guard !fillers.isEmpty else {
                    toolMessage = "Aucun « euh » ni « hum » reconnu dans ce clip."
                    return
                }
                apply("Supprimer les mots parasites") { $0.removeRanges(fillers.map { ($0.start, $0.end) }, from: clipID) }
                toolMessage = "\(fillers.count) mots parasites retirés."
            } catch {
                AppModel.shared.alert = AppAlert(title: "Analyse impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: LUT

    func importLUTPanel() {
        let panel = NSOpenPanel()
        panel.title = "Importer un LUT"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        var last: String?
        for url in panel.urls {
            do { last = try LUTLibrary.install(url) }
            catch { AppModel.shared.alert = AppAlert(title: "LUT refusé", message: "\(url.lastPathComponent) : seuls les LUT 3D au format .cube sont pris en charge.") }
        }
        if let last { useLUT(last) }
    }

    func useLUT(_ name: String) {
        let targets = visualSelection
        guard !targets.isEmpty else {
            var created: UUID?
            let t = playhead
            apply("Ajouter le LUT") { created = $0.addFilterClip(LUTLibrary.prefix + name, name: name, at: t) }
            if let created { selection = [created] }
            return
        }
        apply("LUT « \(name) »") { p in
            for c in targets { p.updateClip(c.id) { $0.filter = FilterRef(id: LUTLibrary.prefix + name) } }
        }
    }

    // MARK: Groupes

    func groupSelection() {
        let ids = selection
        guard ids.count > 1 else { return }
        let group = UUID()
        apply("Grouper") { p in for id in ids { p.updateClip(id) { $0.groupID = group } } }
    }

    func ungroupSelection() {
        let ids = selection
        apply("Dissocier") { p in for id in ids { p.updateClip(id) { $0.groupID = nil } } }
    }

    func groupMembers(of id: UUID) -> Set<UUID> {
        guard let g = project.clip(id)?.groupID else { return [id] }
        return Set(project.tracks.flatMap(\.clips).filter { $0.groupID == g }.map(\.id))
    }

    // MARK: Clips composés

    /// Rassemble les clips sélectionnés en un seul clip (rendu en vidéo), décomposable ensuite.
    func makeCompound() {
        let ids = selection
        guard ids.count > 1 else { return }
        var sub = project
        let start = ids.compactMap { project.clip($0)?.start }.min() ?? .zero
        for ti in sub.tracks.indices {
            sub.tracks[ti].clips = sub.tracks[ti].clips.filter { ids.contains($0.id) }.map { var c = $0; c.start = c.start - start; return c }
            sub.tracks[ti].isMain = false
        }
        sub.tracks.removeAll { $0.clips.isEmpty }
        sub.markers = []
        guard let data = try? ProjectStore.encoder.encode(sub) else { return }
        let n = project.media.filter { $0.name.hasPrefix("Clip composé") }.count + 1
        let out = generatedMediaFolder.appendingPathComponent("Clip composé \(n).mov")
        let topTrack = ids.compactMap { project.trackIndex(of: $0) }.max() ?? 0
        let fromMain = ids.contains { id in project.trackIndex(of: id).map { project.tracks[$0].isMain } ?? false }
        status("Création du clip composé…")
        Task {
            defer { status(nil) }
            do {
                var settings = ExportSettings(destination: out)
                settings.container = .mov
                settings.resolution = .project
                settings.frameRate = project.settings.frameRate
                settings.bitrateChoice = .custom
                settings.customMbps = 40
                try await Exporter().run(project: sub, settings: settings) { _ in }
                guard let mediaID = await importMedia([out]).first else { return }
                apply("Créer un clip composé") { p in
                    p.delete(ids)
                    if let created = p.addMedia(mediaID, at: start, target: fromMain ? .existing(0) : .existing(min(topTrack, p.tracks.count - 1))) {
                        p.updateClip(created) { c in
                            c.name = "Clip composé \(n)"
                            c.compoundSource = data
                        }
                    }
                }
            } catch {
                AppModel.shared.alert = AppAlert(title: "Clip composé impossible", message: error.localizedDescription)
            }
        }
    }

    func breakCompound(_ clipID: UUID) {
        guard let clip = project.clip(clipID), let data = clip.compoundSource,
              let sub = try? ProjectStore.decoder.decode(Project.self, from: data) else { return }
        apply("Décomposer le clip") { p in
            p.delete([clipID])
            for track in sub.tracks {
                var t = Track(kind: track.kind)
                t.clips = track.clips.map { var c = $0; c.id = UUID(); c.start = c.start + clip.start; return c }
                p.tracks.append(t)
            }
            for m in sub.media where p.media(m.id) == nil { p.media.append(m) }
        }
    }

    // MARK: Modèles

    func saveAsTemplate(name: String) {
        var t = project
        t.name = name
        guard let data = try? ProjectStore.encoder.encode(t) else { return }
        let url = TemplateLibrary.folder.appendingPathComponent("\(ProjectStore.sanitize(name)).json")
        do {
            try data.write(to: url, options: .atomic)
            toolMessage = "Modèle « \(name) » enregistré."
        } catch {
            AppModel.shared.alert = AppAlert(title: "Modèle non enregistré", message: error.localizedDescription)
        }
    }

    // MARK: Charte graphique

    func applyBrandColor(_ color: RGBA) {
        let ids = selection
        apply("Couleur de la charte") { p in
            for id in ids {
                p.updateClip(id) { c in
                    if c.text != nil { c.text?.color = color } else if c.isSticker { c.stickerColor = color }
                }
            }
        }
    }

    func applyBrandFont(_ font: String) {
        let ids = selection
        apply("Police de la charte") { p in for id in ids { p.updateClip(id) { $0.text?.fontName = font } } }
    }

    func addBrandLogo() {
        let kit = BrandKit.load()
        guard let path = kit.logoPath else { return }
        Task {
            guard let id = await importMedia([URL(fileURLWithPath: path)]).first else { return }
            var created: UUID?
            apply("Ajouter le logo") { p in
                created = p.addMedia(id, at: .zero, target: .newTrack)
                if let created {
                    p.updateClip(created) { c in
                        c.duration = max(RTime(seconds: 1), p.duration)
                        c.fit = .fit
                        c.transform.scale = 0.16
                        c.transform.positionX = 0.4
                        c.transform.positionY = -0.4
                        c.opacity = 0.9
                    }
                }
            }
            if let created { selection = [created] }
        }
    }
}

/// Modèles de projet enregistrés par l'utilisateur.
enum TemplateLibrary {
    static var folder: URL { AppPaths.ensure(AppPaths.applicationSupport.appendingPathComponent("Modèles", isDirectory: true)) }

    struct Template: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: URL { url }
    }

    static var all: [Template] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { Template(name: ($0.lastPathComponent as NSString).deletingPathExtension, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Projet tiré d'un modèle : mêmes pistes, textes, effets et réglages ; nouveaux identifiants.
    static func project(from url: URL, name: String) throws -> Project {
        let data = try Data(contentsOf: url)
        var p = try ProjectStore.decoder.decode(Project.self, from: data)
        ProjectStore.migrate(&p)
        p.id = UUID()
        p.name = name
        p.createdAt = Date()
        p.modifiedAt = Date()
        p.normalize(magnetic: true)
        return p
    }
}

/// Charte graphique : couleurs, polices et logo réutilisables dans tous les projets.
struct BrandKit: Codable, Equatable {
    var colors: [RGBA] = [RGBA(r: 1, g: 0.33, b: 0.33), RGBA(r: 1, g: 0.8, b: 0.2), RGBA(r: 0.2, g: 0.6, b: 1), .white, .black]
    var titleFont = "Futura"
    var bodyFont = "Helvetica Neue"
    var logoPath: String? = nil

    static func load() -> BrandKit {
        guard let data = UserDefaults.standard.data(forKey: "charte"), let kit = try? JSONDecoder().decode(BrandKit.self, from: data) else { return BrandKit() }
        return kit
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "charte") }
    }
}
