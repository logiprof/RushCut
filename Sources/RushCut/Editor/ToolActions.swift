import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

extension Project {
    /// Retire des parties d'un clip (instants relatifs au clip) ; les morceaux restants se suivent sans vide.
    @discardableResult
    mutating func removeRanges(_ ranges: [(RTime, RTime)], from clipID: UUID) -> [UUID] {
        guard let loc = location(of: clipID), !tracks[loc.track].isLocked else { return [] }
        let original = tracks[loc.track].clips[loc.clip]
        let fps = settings.frameRate
        let minimum = RTime.frame(fps: fps) * 2
        // Parties à garder.
        var keep: [(RTime, RTime)] = []
        var cursor = RTime.zero
        for (a, b) in ranges.sorted(by: { $0.0 < $1.0 }) {
            let a2 = max(.zero, min(a, original.duration)).snapped(fps: fps), b2 = max(.zero, min(b, original.duration)).snapped(fps: fps)
            if a2 > cursor { keep.append((cursor, a2)) }
            cursor = max(cursor, b2)
        }
        if cursor < original.duration { keep.append((cursor, original.duration)) }
        keep = keep.filter { $0.1 - $0.0 >= minimum }
        guard !keep.isEmpty else { return [] }
        var pieces: [Clip] = []
        var start = original.start
        for (i, (a, b)) in keep.enumerated() {
            var c = original
            if i > 0 {
                c.id = UUID()
                c.transitionIn = nil
                c.animIn = nil
            }
            if i < keep.count - 1 { c.animOut = nil; c.audio.fadeOut = .zero }
            if i > 0 { c.audio.fadeIn = .zero }
            c.start = start
            c.duration = b - a
            if c.mediaID != nil { c.sourceIn = original.sourceIn + a * max(0.01, original.speed.rate) }
            c.shiftKeyframes(by: a)
            c.linkedClipIDs = []
            pieces.append(c)
            start = start + c.duration
        }
        var clips = tracks[loc.track].clips
        clips.remove(at: loc.clip)
        clips.insert(contentsOf: pieces, at: loc.clip)
        tracks[loc.track].clips = clips
        return pieces.map(\.id)
    }

    /// Images clés de zoom : avant, maintien, retour (instants relatifs au clip).
    mutating func addZoom(_ clipID: UUID, at local: RTime, focusX: Double, focusY: Double, factor: Double,
                          zoomIn: Double = 0.4, hold: Double = 1.5, zoomOut: Double = 0.4) {
        guard let loc = location(of: clipID) else { return }
        let fps = settings.frameRate
        var c = tracks[loc.track].clips[loc.clip]
        let s0 = c.value(.scale, at: local), x0 = c.value(.positionX, at: local), y0 = c.value(.positionY, at: local)
        let s1 = s0 * factor
        let x1 = -s1 * (focusX - x0) / s0, y1 = -s1 * (focusY - y0) / s0
        let t0 = local
        let t1 = local + RTime(seconds: zoomIn)
        let t2 = t1 + RTime(seconds: hold)
        let t3 = t2 + RTime(seconds: zoomOut)
        for (t, s, x, y) in [(t0, s0, x0, y0), (t1, s1, x1, y1), (t2, s1, x1, y1), (t3, s0, x0, y0)] where t <= c.duration {
            for (prop, v) in [(KeyProp.scale, s), (.positionX, x), (.positionY, y)] {
                var keys = c.keyframes[prop.rawValue] ?? []
                if keys.isEmpty && t != t0 { keys.append(Keyframe(time: t0.snapped(fps: fps), value: c.baseValue(prop))) }
                keys.removeAll { abs(($0.time - t).seconds) < 0.5 / Double(fps) }
                keys.append(Keyframe(time: t.snapped(fps: fps), value: v, interpolation: .douce))
                keys.sort { $0.time < $1.time }
                c.keyframes[prop.rawValue] = keys
            }
        }
        tracks[loc.track].clips[loc.clip] = c
    }

    /// Clip vidéo visible sous un calque à un instant (le plus haut d'abord).
    func videoClip(under clipID: UUID, at time: RTime) -> Clip? {
        guard let ti = trackIndex(of: clipID) else { return nil }
        for i in stride(from: ti - 1, through: 0, by: -1) where tracks[i].kind.isVisual && !tracks[i].isHidden {
            if let c = tracks[i].clips.first(where: { $0.contains(time) && media($0.mediaID)?.kind == .video }) { return c }
        }
        return nil
    }
}

/// Outils de montage du lot V1 : silences, image figée, inverser, remplacer, suivi, zoom, proxys, versions, médias.
extension EditorModel {
    func setInPoint() { inPoint = playhead; if let o = outPoint, o <= playhead { outPoint = nil } }
    func setOutPoint() { outPoint = playhead; if let i = inPoint, i >= playhead { inPoint = nil } }
    func clearInOut() { inPoint = nil; outPoint = nil }

    private func busy(_ message: String?) { toolStatus = message }

    // MARK: Silences

    func removeSilences(_ clipID: UUID) {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID), media.hasAudio || media.kind == .audio,
              let url = MediaResolver.url(for: media) else { return }
        busy("Recherche des silences…")
        Task {
            defer { busy(nil) }
            do {
                let levels = try await SilenceDetector.levels(url: url, start: clip.sourceIn.seconds, duration: clip.sourceLength.seconds)
                let rate = max(0.01, clip.speed.rate)
                let silences = SilenceDetector.silences(levels: levels).map { (RTime(seconds: $0.0 / rate), RTime(seconds: $0.1 / rate)) }
                guard !silences.isEmpty else {
                    AppModel.shared.alert = AppAlert(title: "Aucun silence trouvé", message: "Ce clip ne contient pas de pause assez longue à retirer.")
                    return
                }
                let removed = silences.map { ($0.1 - $0.0).seconds }.reduce(0, +)
                apply("Supprimer les silences") { $0.removeRanges(silences, from: clipID) }
                toolMessage = String(format: "%d silences retirés (%.1f s).", silences.count, removed)
            } catch {
                AppModel.shared.alert = AppAlert(title: "Analyse impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Image figée

    func freezeFrame(_ clipID: UUID, seconds: Double = 3) {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID), media.kind == .video,
              let url = MediaResolver.url(for: media), let local = localTime(in: clip) else { return }
        let source = clip.sourceIn.seconds + local.seconds * clip.speed.rate
        let at = playhead
        let file = generatedMediaFolder.appendingPathComponent("Image figée \(Int(Date().timeIntervalSince1970)).png")
        Task {
            do {
                let image = try await FrameGrabber.image(url: url, at: source)
                try ExtraExporters.writePNG(image, to: file)
                guard let id = await importMedia([file]).first else { return }
                let isMain = project.trackIndex(of: clipID).map { project.tracks[$0].isMain } ?? false
                var created: UUID?
                apply("Image figée") { p in
                    if isMain { _ = p.split(at: at, clipIDs: [clipID]) }
                    created = p.addMedia(id, at: at, target: isMain ? .existing(0) : .newTrack)
                    if let created { p.updateClip(created) { c in c.duration = RTime(seconds: seconds); c.fit = clip.fit; c.transform = clip.transform } }
                }
                if let created { selection = [created] }
            } catch {
                AppModel.shared.alert = AppAlert(title: "Image figée impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Inverser

    func reverseClip(_ clipID: UUID) {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID), media.kind == .video,
              let url = MediaResolver.url(for: media) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let base = (media.name as NSString).deletingPathExtension
        let videoOut = generatedMediaFolder.appendingPathComponent("\(base) (inversé \(stamp)).mov")
        let audioOut = generatedMediaFolder.appendingPathComponent("\(base) (son inversé \(stamp)).caf")
        busy("Inversion de la vidéo…")
        Task {
            defer { busy(nil) }
            do {
                let start = clip.sourceIn.seconds, length = clip.sourceLength.seconds
                try await Reverser.reverseVideo(source: url, start: start, duration: length, to: videoOut) { p in
                    Task { @MainActor in self.toolStatus = "Inversion de la vidéo… \(Int(p * 100)) %" }
                }
                let hasAudio = media.hasAudio && !clip.audio.isMuted ? try await Reverser.reverseAudio(source: url, start: start, duration: length, to: audioOut) : false
                let ids = await importMedia(hasAudio ? [videoOut, audioOut] : [videoOut])
                guard let videoID = ids.first else { return }
                apply("Inverser le clip") { p in
                    p.updateClip(clipID) { c in
                        c.mediaID = videoID
                        c.sourceIn = .zero
                        c.name = "\(c.name) (inversé)"
                        if hasAudio { c.audio.isMuted = true }
                    }
                    if hasAudio, ids.count > 1, let audioClip = p.addMedia(ids[1], at: clip.start, target: .newTrack) {
                        p.updateClip(audioClip) { a in
                            a.duration = clip.duration
                            a.speed = clip.speed
                            a.audio.volumeDB = clip.audio.volumeDB
                            a.linkedClipIDs = [clipID]
                        }
                        p.updateClip(clipID) { $0.linkedClipIDs.append(audioClip) }
                    }
                }
            } catch {
                AppModel.shared.alert = AppAlert(title: "Inversion impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Remplacer

    func replaceClipPanel(_ clipID: UUID) {
        guard let clip = project.clip(clipID) else { return }
        let panel = NSOpenPanel()
        panel.title = "Remplacer « \(clip.name) »"
        panel.message = "La durée, la position, les effets et les animations sont conservés."
        panel.allowedContentTypes = [.movie, .image, .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let id = await importMedia([url]).first, let media = project.media(id) else { return }
            apply("Remplacer le clip") { p in
                p.updateClip(clipID) { c in
                    c.mediaID = id
                    c.name = media.name
                    c.sourceIn = .zero
                    if media.kind != .image, media.duration < c.sourceLength {
                        c.duration = RTime(ticks: Int64(Double(media.duration.ticks) / max(0.01, c.speed.rate)))
                    }
                }
            }
        }
    }

    // MARK: Zoom sur une zone

    func addZoom(_ clipID: UUID, focusX: Double, focusY: Double, factor: Double, hold: Double) {
        guard let clip = project.clip(clipID), let local = localTime(in: clip) else { return }
        apply("Zoom sur une zone") { $0.addZoom(clipID, at: local, focusX: focusX, focusY: focusY, factor: factor, hold: hold) }
    }

    // MARK: Suivi de mouvement

    /// Fait suivre au calque (texte, autocollant, image) ce qui se trouve sous lui dans la vidéo.
    func trackMotion(_ clipID: UUID) {
        guard let overlay = project.clip(clipID), let local = localTime(in: overlay) else { return }
        let time = playhead
        guard let video = project.videoClip(under: clipID, at: time), let media = project.media(video.mediaID),
              let url = MediaResolver.url(for: media) else {
            AppModel.shared.alert = AppAlert(title: "Suivi impossible", message: "Placez le calque au-dessus d'une vidéo, la tête de lecture sur l'instant où commence le suivi.")
            return
        }
        let canvas = project.settings.canvasSize
        let source = Geometry.croppedSize(media.pixelSize, crop: video.crop)
        let geometry = Geometry.layer(sourceSize: source, canvas: canvas, fit: video.fit, transform: video.transform)
        let c = geometry.corners
        let origin = c[0], e1 = CGPoint(x: c[1].x - c[0].x, y: c[1].y - c[0].y), e2 = CGPoint(x: c[3].x - c[0].x, y: c[3].y - c[0].y)
        let px = (overlay.value(.positionX, at: local) + 0.5) * canvas.width
        let py = (overlay.value(.positionY, at: local) + 0.5) * canvas.height
        // Point du calque dans l'image vidéo (u, v entre 0 et 1).
        let det = e1.x * e2.y - e1.y * e2.x
        guard abs(det) > 1 else { return }
        let dx = px - origin.x, dy = py - origin.y
        let u = (dx * e2.y - dy * e2.x) / det, v = (e1.x * dy - e1.y * dx) / det
        guard (0...1).contains(u), (0...1).contains(v) else {
            AppModel.shared.alert = AppAlert(title: "Suivi impossible", message: "Le centre du calque doit être sur la vidéo.")
            return
        }
        let side = 0.12
        let aspect = source.width / max(source.height, 1)
        let region = CGRect(x: u - side / 2 / aspect, y: v - side / 2, width: side / aspect, height: side).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rate = max(0.01, video.speed.rate)
        let sourceStart = video.sourceIn.seconds + (time - video.start).seconds * rate
        let span = min(overlay.end, video.end) - time
        busy("Suivi du mouvement…")
        Task {
            defer { busy(nil) }
            do {
                let points = try await MotionTracker.track(url: url, start: sourceStart, duration: span.seconds * rate, region: region) { p in
                    Task { @MainActor in self.toolStatus = "Suivi du mouvement… \(Int(p * 100)) %" }
                }
                guard points.count > 2, let first = points.first else {
                    AppModel.shared.alert = AppAlert(title: "Suivi impossible", message: "La zone sous le calque n'a pas pu être suivie (trop peu de détails ou mouvement trop rapide).")
                    return
                }
                func canvasPoint(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: origin.x + e1.x * x + e2.x * y, y: origin.y + e1.y * x + e2.y * y)
                }
                let start = canvasPoint(first.x, first.y)
                let offsetX = px - start.x, offsetY = py - start.y
                let fps = project.settings.frameRate
                apply("Suivi du mouvement") { p in
                    p.updateClip(clipID) { c in
                        var xs: [Keyframe] = [], ys: [Keyframe] = []
                        for (i, pt) in points.enumerated() where i % 2 == 0 || i == points.count - 1 {
                            let timelineTime = video.start + RTime(seconds: (pt.sourceTime - video.sourceIn.seconds) / rate)
                            let t = (timelineTime - c.start).snapped(fps: fps)
                            guard t >= .zero, t <= c.duration else { continue }
                            let q = canvasPoint(pt.x, pt.y)
                            xs.append(Keyframe(time: t, value: (q.x + offsetX) / canvas.width - 0.5, interpolation: .lineaire))
                            ys.append(Keyframe(time: t, value: (q.y + offsetY) / canvas.height - 0.5, interpolation: .lineaire))
                        }
                        c.keyframes[KeyProp.positionX.rawValue] = xs
                        c.keyframes[KeyProp.positionY.rawValue] = ys
                    }
                }
                toolMessage = "Suivi terminé : \(points.count) images analysées."
            } catch {
                AppModel.shared.alert = AppAlert(title: "Suivi impossible", message: error.localizedDescription)
            }
        }
    }

    // MARK: Proxys

    func setUseProxies(_ on: Bool) {
        useProxies = on
        UserDefaults.standard.set(on, forKey: "proxys")
        if on { createProxies() }
        rebuild(immediately: true)
    }

    func createProxies() {
        let jobs = project.media.filter { ProxyStore.isWorthwhile($0) && ProxyStore.existing($0) == nil }
            .compactMap { m in MediaResolver.url(for: m).map { (m, $0) } }
        guard !jobs.isEmpty else { return }
        busy("Création des proxys (0/\(jobs.count))…")
        Task {
            defer { busy(nil) }
            for (i, (media, url)) in jobs.enumerated() {
                toolStatus = "Création des proxys (\(i + 1)/\(jobs.count))…"
                do { try await ProxyStore.create(for: media, source: url) } catch { Log.error("Proxy \(media.name) : \(error.localizedDescription)") }
            }
            rebuild(immediately: true)
        }
    }

    /// Fichier utilisé pour l'aperçu (le proxy quand il existe et que l'option est active).
    nonisolated static func previewResolver(useProxies: Bool) -> (MediaRef) -> URL? {
        { media in
            if useProxies, let proxy = ProxyStore.existing(media) { return proxy }
            return MediaResolver.url(for: media)
        }
    }

    // MARK: Rassembler les médias

    /// Copie tous les médias dans le dossier du projet (pour l'archiver ou le déplacer sur un autre Mac).
    func collectMedia() {
        let folder = generatedMediaFolder
        let jobs = project.media.compactMap { m -> (UUID, URL)? in
            guard let url = MediaResolver.url(for: m), !url.path.hasPrefix(folder.path) else { return nil }
            return (m.id, url)
        }
        guard !jobs.isEmpty else {
            toolMessage = "Tous les médias sont déjà dans le projet."
            return
        }
        busy("Copie des médias…")
        Task {
            defer { busy(nil) }
            var moved: [UUID: String] = [:]
            for (i, (id, url)) in jobs.enumerated() {
                toolStatus = "Copie des médias (\(i + 1)/\(jobs.count))…"
                var target = folder.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(id.uuidString.prefix(6))-\(url.lastPathComponent)")
                }
                do {
                    try await Task.detached { try FileManager.default.copyItem(at: url, to: target) }.value
                    moved[id] = target.path
                } catch {
                    Log.error("Copie de \(url.lastPathComponent) : \(error.localizedDescription)")
                }
            }
            apply("Rassembler les médias") { p in
                for i in p.media.indices {
                    if let path = moved[p.media[i].id] {
                        p.media[i].path = path
                        p.media[i].bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
                    }
                }
            }
            toolMessage = "\(moved.count) médias copiés dans le projet."
        }
    }

    // MARK: Versions

    func restoreVersion(_ version: ProjectStore.SavedVersion) {
        do {
            var restored = try ProjectStore.loadVersion(version)
            restored.id = project.id
            if let data = try? ProjectStore.encoder.encode(project) { ProjectStore.archiveVersion(data, in: url, force: true) }
            apply("Restaurer une version") { $0 = restored }
        } catch {
            AppModel.shared.alert = AppAlert(title: "Version illisible", message: error.localizedDescription)
        }
    }

    // MARK: Conversion

    /// Convertit (avec le module FFmpeg) puis importe des fichiers qu'AVFoundation ne lit pas.
    func convertAndImport(_ urls: [URL]) {
        guard FFmpegModule.isInstalled else {
            pendingConversion = urls
            return
        }
        busy("Conversion de \(urls.count) fichier(s)…")
        let folder = generatedMediaFolder
        Task {
            defer { busy(nil) }
            var converted: [URL] = []
            for (i, u) in urls.enumerated() {
                toolStatus = "Conversion (\(i + 1)/\(urls.count)) : \(u.lastPathComponent)…"
                do { converted.append(try await FFmpegModule.convert(u, into: folder)) }
                catch { AppModel.shared.alert = AppAlert(title: "Conversion impossible", message: "\(u.lastPathComponent) : \(error.localizedDescription)") }
            }
            if !converted.isEmpty { await importMedia(converted) }
        }
    }
}
