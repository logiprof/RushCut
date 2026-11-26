import Foundation

/// Où déposer un clip déplacé.
enum TrackTarget: Equatable {
    case existing(Int)
    /// Nouvelle piste au-dessus de toutes les autres (visuel) ou en dessous (audio).
    case newTrack
}

enum TrimEdge {
    case start, end
}

/// Toutes les opérations de montage, sous forme de fonctions pures sur le projet.
/// L'interface les appelle à travers `EditorModel.apply`, qui les rend annulables.
extension Project {

    // MARK: - Lecture

    var duration: RTime {
        tracks.lazy.flatMap(\.clips).map(\.end).max() ?? .zero
    }

    func media(_ id: UUID?) -> MediaRef? {
        guard let id else { return nil }
        return media.first { $0.id == id }
    }

    func clip(_ id: UUID) -> Clip? {
        guard let loc = location(of: id) else { return nil }
        return tracks[loc.track].clips[loc.clip]
    }

    func location(of clipID: UUID) -> (track: Int, clip: Int)? {
        for (ti, track) in tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipID }) { return (ti, ci) }
        }
        return nil
    }

    func trackIndex(of clipID: UUID) -> Int? { location(of: clipID)?.track }

    var mainTrackIndex: Int? { tracks.firstIndex { $0.isMain } }

    func isUsed(mediaID: UUID) -> Bool {
        tracks.contains { $0.clips.contains { $0.mediaID == mediaID } }
    }

    func isCompatible(_ clip: Clip, with kind: TrackKind, onAudioTrack: Bool) -> Bool {
        if clip.isText { return kind == .text || kind == .sticker }
        if clip.isSticker { return kind == .sticker || kind == .text }
        if clip.isEffectOnly { return kind == .effect }
        guard let m = media(clip.mediaID) else { return kind.isVisual }
        switch m.kind {
        case .audio: return kind == .audio
        case .image: return kind == .video || kind == .sticker
        case .video: return onAudioTrack ? kind == .audio : kind == .video
        }
    }

    func isFree(track index: Int, start: RTime, end: RTime, excluding: Set<UUID> = []) -> Bool {
        guard tracks.indices.contains(index) else { return false }
        return !tracks[index].clips.contains { c in
            !excluding.contains(c.id) && c.start < end && start < c.end
        }
    }

    /// Points d'aimantation : début, tête de lecture, bords des clips et marqueurs.
    func snapPoints(excluding: Set<UUID>, playhead: RTime) -> [RTime] {
        var points: [RTime] = [.zero, playhead]
        for track in tracks {
            for c in track.clips where !excluding.contains(c.id) {
                points.append(c.start)
                points.append(c.end)
            }
        }
        points.append(contentsOf: markers.map(\.time))
        return points
    }

    // MARK: - Pistes

    mutating func ensureMainTrack() {
        if let i = tracks.firstIndex(where: { $0.isMain }) {
            for j in tracks.indices where j != i { tracks[j].isMain = false }
            if i != 0 {
                let main = tracks.remove(at: i)
                tracks.insert(main, at: 0)
            }
            return
        }
        if let i = tracks.firstIndex(where: { $0.kind == .video }) {
            tracks[i].isMain = true
            let main = tracks.remove(at: i)
            tracks.insert(main, at: 0)
        } else {
            tracks.insert(Track(kind: .video, isMain: true), at: 0)
        }
    }

    /// Crée une piste. Les pistes visuelles sont empilées : la dernière est dessinée au-dessus.
    @discardableResult
    mutating func addTrack(kind: TrackKind, above index: Int? = nil) -> Int {
        let track = Track(kind: kind)
        if kind.isVisual, let index, index + 1 <= tracks.count {
            tracks.insert(track, at: index + 1)
            return index + 1
        }
        tracks.append(track)
        return tracks.count - 1
    }

    /// Trouve une piste libre du bon type (hors piste principale) ou en crée une.
    mutating func freeTrack(kind: TrackKind, start: RTime, end: RTime, excluding: Set<UUID> = [], preferAbove: Int? = nil) -> Int {
        let candidates = tracks.indices.filter { tracks[$0].kind == kind && !tracks[$0].isMain && !tracks[$0].isLocked }
        if let preferAbove {
            for i in candidates where i > preferAbove && isFree(track: i, start: start, end: end, excluding: excluding) { return i }
        }
        for i in candidates where isFree(track: i, start: start, end: end, excluding: excluding) { return i }
        return addTrack(kind: kind, above: preferAbove)
    }

    // MARK: - Ajout

    /// Insère un clip sur la piste principale magnétique.
    /// `anchor` : instant qui décide de l'ordre (le clip se place avant le premier clip dont le milieu est après).
    /// `originalStart` : position avant l'opération, pour que le son détaché suive du même décalage.
    mutating func insertOnMain(_ clip: Clip, anchor: RTime, originalStart: RTime? = nil) {
        ensureMainTrack()
        var clips = tracks[0].clips.sorted { $0.start < $1.start }
        var originals: [UUID: RTime] = [:]
        for c in clips { originals[c.id] = c.start }
        if let originalStart { originals[clip.id] = originalStart }
        let index = clips.firstIndex { $0.start + RTime(ticks: $0.duration.ticks / 2) > anchor } ?? clips.count
        clips.insert(clip, at: index)
        layoutMainTrack(clips, originalStarts: originals)
    }

    /// Place un clip sur une piste donnée ; si la place est prise, sur une piste libre du même type.
    @discardableResult
    mutating func place(_ clip: Clip, target: TrackTarget, asAudio: Bool = false) -> Int {
        var c = clip
        c.start = max(.zero, c.start)
        let kind: TrackKind = asAudio ? .audio : preferredKindForPlacement(c)
        switch target {
        case .existing(let i) where tracks.indices.contains(i):
            let track = tracks[i]
            let compatible = isCompatible(c, with: track.kind, onAudioTrack: asAudio)
            if compatible && !track.isLocked {
                if track.isMain {
                    insertOnMain(c, anchor: c.start)
                    return 0
                }
                if isFree(track: i, start: c.start, end: c.end) {
                    tracks[i].clips.append(c)
                    tracks[i].clips.sort { $0.start < $1.start }
                    return i
                }
                let j = freeTrack(kind: track.kind, start: c.start, end: c.end, preferAbove: i)
                tracks[j].clips.append(c)
                tracks[j].clips.sort { $0.start < $1.start }
                return j
            }
            fallthrough
        default:
            let j = freeTrack(kind: kind, start: c.start, end: c.end, preferAbove: kind.isVisual ? tracks.count - 1 : nil)
            tracks[j].clips.append(c)
            tracks[j].clips.sort { $0.start < $1.start }
            return j
        }
    }

    func preferredKindForPlacement(_ clip: Clip) -> TrackKind {
        if clip.isText { return .text }
        if clip.isSticker { return .sticker }
        if clip.isEffectOnly { return .effect }
        guard let m = media(clip.mediaID) else { return .video }
        return m.kind == .audio ? .audio : .video
    }

    /// Crée un clip pour un média.
    func makeClip(for media: MediaRef, at start: RTime) -> Clip {
        var clip = Clip()
        clip.mediaID = media.id
        clip.name = media.name
        clip.start = start
        clip.sourceIn = .zero
        switch media.kind {
        case .image:
            clip.duration = media.isAnimated && media.duration > .zero ? media.duration : RTime(seconds: 5)
        case .video, .audio:
            clip.duration = media.duration > .zero ? media.duration : RTime(seconds: 5)
        }
        clip.duration = clip.duration.snapped(fps: settings.frameRate)
        if clip.duration <= .zero { clip.duration = RTime.frame(fps: settings.frameRate) }
        return clip
    }

    /// Ajoute un média : vidéo et image à la fin de la piste principale ou sur une piste au-dessus,
    /// audio sur une piste audio libre.
    @discardableResult
    mutating func addMedia(_ mediaID: UUID, at time: RTime?, target: TrackTarget? = nil) -> UUID? {
        guard let m = media(mediaID) else { return nil }
        ensureMainTrack()
        var clip = makeClip(for: m, at: time ?? .zero)
        if m.kind == .audio {
            clip.start = time ?? .zero
            place(clip, target: target ?? .newTrack)
            return clip.id
        }
        if let target {
            place(clip, target: target)
        } else if let time {
            clip.start = time
            insertOnMain(clip, anchor: time)
        } else {
            clip.start = tracks[0].clips.map(\.end).max() ?? .zero
            insertOnMain(clip, anchor: RTime(ticks: Int64.max / 4))
        }
        return clip.id
    }

    @discardableResult
    mutating func addText(_ content: TextContent, at time: RTime, duration: RTime = RTime(seconds: 3)) -> UUID {
        var clip = Clip()
        clip.name = String(content.string.prefix(30))
        clip.text = content
        clip.start = time.snapped(fps: settings.frameRate)
        clip.duration = duration
        clip.fit = .none
        place(clip, target: .newTrack)
        return clip.id
    }

    // MARK: - Modification d'un clip

    mutating func updateClip(_ id: UUID, _ body: (inout Clip) -> Void) {
        guard let loc = location(of: id), !tracks[loc.track].isLocked else { return }
        body(&tracks[loc.track].clips[loc.clip])
        clampFades(&tracks[loc.track].clips[loc.clip])
    }

    private func clampFades(_ clip: inout Clip) {
        if clip.audio.fadeIn < .zero { clip.audio.fadeIn = .zero }
        if clip.audio.fadeOut < .zero { clip.audio.fadeOut = .zero }
        if clip.audio.fadeIn > clip.duration { clip.audio.fadeIn = clip.duration }
        if clip.audio.fadeIn + clip.audio.fadeOut > clip.duration {
            clip.audio.fadeOut = clip.duration - clip.audio.fadeIn
        }
    }

    /// Durée maximale disponible dans le média à partir d'un point d'entrée (nil = illimitée : image, texte).
    func availableSourceDuration(for clip: Clip) -> RTime? {
        guard let m = media(clip.mediaID) else { return nil }
        switch m.kind {
        case .video, .audio:
            let remaining = max(.zero, m.duration - clip.sourceIn)
            return RTime(ticks: Int64(Double(remaining.ticks) / max(0.01, clip.speed.rate)))
        case .image: return nil
        }
    }

    func hasFiniteSource(_ clip: Clip) -> Bool {
        guard let m = media(clip.mediaID) else { return false }
        return m.kind == .video || m.kind == .audio
    }

    // MARK: - Couper

    /// Coupe les clips à `time`. Sans sélection : tous les clips sous la tête de lecture (pistes non verrouillées).
    @discardableResult
    mutating func split(at time: RTime, clipIDs: Set<UUID>) -> [UUID] {
        let fps = settings.frameRate
        let t = time.snapped(fps: fps)
        let minimum = RTime.frame(fps: fps)
        var targets = Set<UUID>()
        for track in tracks where !track.isLocked {
            for c in track.clips where (clipIDs.isEmpty || clipIDs.contains(c.id)) {
                if c.start + minimum <= t && t <= c.end - minimum { targets.insert(c.id) }
            }
        }
        // Les clips liés (son détaché) sont coupés ensemble.
        for id in targets {
            if let c = clip(id) {
                for linked in c.linkedClipIDs {
                    if let l = clip(linked), l.start + minimum <= t, t <= l.end - minimum,
                       let ti = trackIndex(of: linked), !tracks[ti].isLocked {
                        targets.insert(linked)
                    }
                }
            }
        }
        var rightIDs: [UUID: UUID] = [:]
        for id in targets { rightIDs[id] = UUID() }
        var created: [UUID] = []
        for ti in tracks.indices {
            var newClips: [Clip] = []
            for c in tracks[ti].clips {
                guard let rightID = rightIDs[c.id] else { newClips.append(c); continue }
                var left = c
                var right = c
                let offset = t - c.start
                left.duration = offset
                left.audio.fadeOut = .zero
                right.id = rightID
                right.start = t
                right.duration = c.end - t
                if c.mediaID != nil { right.sourceIn = c.sourceIn + offset * max(0.01, c.speed.rate) }
                right.audio.fadeIn = .zero
                right.shiftKeyframes(by: offset)
                right.transitionIn = nil
                right.animIn = nil
                left.animOut = nil
                right.linkedClipIDs = c.linkedClipIDs.compactMap { rightIDs[$0] }
                left.linkedClipIDs = c.linkedClipIDs.filter { rightIDs[$0] != nil || clip($0) != nil }
                clampFades(&left)
                clampFades(&right)
                newClips.append(left)
                newClips.append(right)
                created.append(rightID)
            }
            tracks[ti].clips = newClips
        }
        return created
    }

    // MARK: - Rogner

    mutating func trim(_ id: UUID, edge: TrimEdge, to time: RTime) {
        guard let loc = location(of: id), !tracks[loc.track].isLocked else { return }
        let fps = settings.frameRate
        let minimum = RTime.frame(fps: fps)
        let track = tracks[loc.track]
        var c = track.clips[loc.clip]
        let others = track.clips.filter { $0.id != id }
        let t = time.snapped(fps: fps)
        switch edge {
        case .start:
            var lower: RTime = .zero
            if hasFiniteSource(c) {
                lower = max(lower, c.start - RTime(ticks: Int64(Double(c.sourceIn.ticks) / max(0.01, c.speed.rate))))
            }
            if !track.isMain, let prev = others.filter({ $0.end <= c.start }).map(\.end).max() {
                lower = max(lower, prev)
            }
            let upper = c.end - minimum
            let newStart = min(max(t, lower), upper)
            let delta = newStart - c.start
            if c.mediaID != nil { c.sourceIn = max(.zero, c.sourceIn + delta * max(0.01, c.speed.rate)) }
            c.duration = c.end - newStart
            c.start = newStart
            c.shiftKeyframes(by: delta)
        case .end:
            var upper = RTime(ticks: Int64.max / 4)
            if let available = availableSourceDuration(for: c) { upper = c.start + available }
            if !track.isMain, let next = others.filter({ $0.start >= c.end }).map(\.start).min() {
                upper = min(upper, next)
            }
            let lower = c.start + minimum
            let newEnd = min(max(t, lower), max(lower, upper))
            c.duration = newEnd - c.start
        }
        clampFades(&c)
        tracks[loc.track].clips[loc.clip] = c
    }

    /// Q : supprime la partie à gauche de la tête de lecture. W : à droite.
    mutating func trimToPlayhead(_ time: RTime, keepRight: Bool, clipIDs: Set<UUID>) {
        let minimum = RTime.frame(fps: settings.frameRate)
        var ids: [UUID] = []
        for track in tracks where !track.isLocked {
            for c in track.clips where (clipIDs.isEmpty || clipIDs.contains(c.id)) {
                if c.start + minimum <= time && time <= c.end - minimum { ids.append(c.id) }
            }
        }
        for id in ids {
            trim(id, edge: keepRight ? .start : .end, to: time)
        }
    }

    // MARK: - Déplacer

    /// Déplace un clip (et ses clips liés du même décalage) vers une position et une piste.
    mutating func move(_ id: UUID, to start: RTime, target: TrackTarget) {
        guard let loc = location(of: id), !tracks[loc.track].isLocked else { return }
        let fps = settings.frameRate
        var c = tracks[loc.track].clips[loc.clip]
        let originalStart = c.start
        let sourceTrack = loc.track
        let isAudioPart = tracks[sourceTrack].kind == .audio
        let delta = max(.zero, start).snapped(fps: fps) - c.start
        tracks[loc.track].clips.remove(at: loc.clip)
        c.start = max(.zero, c.start + delta)

        var resolved = target
        if case .existing(let i) = target {
            if !tracks.indices.contains(i) || tracks[i].isLocked
                || !isCompatible(c, with: tracks[i].kind, onAudioTrack: isAudioPart) {
                resolved = .existing(sourceTrack)
            }
        }
        var placedOnMain = false
        switch resolved {
        case .newTrack:
            let kind: TrackKind = isAudioPart ? .audio : preferredKindForPlacement(c)
            let index = addTrack(kind: kind, above: kind.isVisual ? tracks.count - 1 : nil)
            tracks[index].clips.append(c)
        case .existing(let i):
            if tracks[i].isMain {
                insertOnMain(c, anchor: c.start + RTime(ticks: c.duration.ticks / 2), originalStart: originalStart)
                placedOnMain = true
            } else if isFree(track: i, start: c.start, end: c.end) {
                tracks[i].clips.append(c)
                tracks[i].clips.sort { $0.start < $1.start }
            } else {
                let j = freeTrack(kind: tracks[i].kind, start: c.start, end: c.end, preferAbove: i)
                tracks[j].clips.append(c)
                tracks[j].clips.sort { $0.start < $1.start }
            }
        }

        // Les clips liés suivent s'ils ont la place (sur la piste principale, le rangement s'en charge).
        guard !placedOnMain, delta != .zero else { return }
        for linked in c.linkedClipIDs {
            guard let l = location(of: linked), !tracks[l.track].isLocked, !tracks[l.track].isMain else { continue }
            var lc = tracks[l.track].clips[l.clip]
            let newStart = max(.zero, lc.start + delta)
            if isFree(track: l.track, start: newStart, end: newStart + lc.duration, excluding: [lc.id]) {
                lc.start = newStart
                tracks[l.track].clips[l.clip] = lc
                tracks[l.track].clips.sort { $0.start < $1.start }
            }
        }
    }

    // MARK: - Supprimer

    mutating func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for ti in tracks.indices where !tracks[ti].isLocked {
            tracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices {
                tracks[ti].clips[ci].linkedClipIDs.removeAll { ids.contains($0) }
            }
        }
    }

    // MARK: - Son détaché

    @discardableResult
    mutating func detachAudio(_ id: UUID) -> UUID? {
        guard let loc = location(of: id), !tracks[loc.track].isLocked else { return nil }
        let c = tracks[loc.track].clips[loc.clip]
        guard tracks[loc.track].kind != .audio, let m = media(c.mediaID), m.kind == .video, m.hasAudio,
              !c.audio.isMuted else { return nil }
        var audioClip = c
        audioClip.id = UUID()
        audioClip.name = c.name + " (son)"
        audioClip.transform = Transform()
        audioClip.crop = CropRect()
        audioClip.linkedClipIDs = [c.id]
        tracks[loc.track].clips[loc.clip].audio.isMuted = true
        tracks[loc.track].clips[loc.clip].linkedClipIDs.append(audioClip.id)
        let j = freeTrack(kind: .audio, start: audioClip.start, end: audioClip.end)
        tracks[j].clips.append(audioClip)
        tracks[j].clips.sort { $0.start < $1.start }
        return audioClip.id
    }

    // MARK: - Dupliquer, coller

    @discardableResult
    mutating func duplicate(_ ids: Set<UUID>) -> [UUID] {
        var created: [UUID] = []
        let ordered = tracks.flatMap(\.clips).filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
        for c in ordered {
            guard let ti = trackIndex(of: c.id) else { continue }
            var copy = c
            copy.id = UUID()
            copy.linkedClipIDs = []
            copy.start = c.end
            if tracks[ti].isMain {
                insertOnMain(copy, anchor: c.end - RTime(ticks: 1))
            } else {
                place(copy, target: .existing(ti), asAudio: tracks[ti].kind == .audio)
            }
            created.append(copy.id)
        }
        return created
    }

    struct ClipboardItem: Hashable {
        var clip: Clip
        var trackID: UUID
        var wasMain: Bool
        var onAudioTrack: Bool
    }

    func clipboardItems(for ids: Set<UUID>) -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        for track in tracks {
            for c in track.clips where ids.contains(c.id) {
                items.append(ClipboardItem(clip: c, trackID: track.id, wasMain: track.isMain, onAudioTrack: track.kind == .audio))
            }
        }
        return items.sorted { $0.clip.start < $1.clip.start }
    }

    @discardableResult
    mutating func paste(_ items: [ClipboardItem], at time: RTime) -> [UUID] {
        guard let base = items.map(\.clip.start).min() else { return [] }
        var created: [UUID] = []
        for item in items {
            var c = item.clip
            c.id = UUID()
            c.linkedClipIDs = []
            c.start = time + (item.clip.start - base)
            if item.wasMain, media(c.mediaID)?.kind != .audio, !c.isText {
                insertOnMain(c, anchor: c.start)
            } else if let ti = tracks.firstIndex(where: { $0.id == item.trackID }), !tracks[ti].isMain {
                place(c, target: .existing(ti), asAudio: item.onAudioTrack)
            } else {
                let kind: TrackKind = item.onAudioTrack ? .audio : preferredKindForPlacement(c)
                let j = freeTrack(kind: kind, start: c.start, end: c.end)
                tracks[j].clips.append(c)
                tracks[j].clips.sort { $0.start < $1.start }
            }
            created.append(c.id)
        }
        return created
    }

    // MARK: - Vitesse

    /// Change la vitesse d'un clip : la durée s'adapte pour garder le même passage de la source.
    mutating func setSpeed(_ id: UUID, rate: Double) {
        let fps = settings.frameRate
        updateClip(id) { c in
            let newRate = min(100, max(0.1, rate))
            let oldRate = max(0.01, c.speed.rate)
            let source = c.sourceLength
            c.speed.rate = newRate
            c.duration = max(RTime.frame(fps: fps), RTime(ticks: Int64(Double(source.ticks) / newRate)).snapped(fps: fps))
            // Les images clés gardent leur place dans la source.
            for (key, list) in c.keyframes {
                c.keyframes[key] = list.map { var k = $0; k.time = RTime(ticks: Int64(Double(k.time.ticks) * oldRate / newRate)); return k }
            }
        }
    }

    // MARK: - Effets, autocollants

    /// Ajoute un clip d'effet (piste d'effets : agit sur tout ce qui est dessous).
    @discardableResult
    mutating func addEffectClip(_ type: String, name: String, at time: RTime, duration: RTime = RTime(seconds: 3)) -> UUID {
        var clip = Clip()
        clip.name = name
        clip.start = time.snapped(fps: settings.frameRate)
        clip.duration = duration
        clip.effects = [EffectInstance(type: type)]
        place(clip, target: .newTrack)
        return clip.id
    }

    /// Ajoute un clip de filtre (piste d'effets).
    @discardableResult
    mutating func addFilterClip(_ id: String, name: String, at time: RTime, duration: RTime = RTime(seconds: 5)) -> UUID {
        var clip = Clip()
        clip.name = name
        clip.start = time.snapped(fps: settings.frameRate)
        clip.duration = duration
        clip.filter = FilterRef(id: id)
        place(clip, target: .newTrack)
        return clip.id
    }

    @discardableResult
    mutating func addSticker(_ id: String, name: String, color: RGBA, at time: RTime, duration: RTime = RTime(seconds: 3)) -> UUID {
        var clip = Clip()
        clip.name = name
        clip.sticker = id
        clip.stickerColor = color
        clip.fit = .none
        clip.start = time.snapped(fps: settings.frameRate)
        clip.duration = duration
        place(clip, target: .newTrack)
        return clip.id
    }

    /// Applique une transition à l'entrée d'un clip de la piste principale (sauf le premier).
    mutating func setTransition(_ type: String?, on id: UUID, duration: RTime = RTime(seconds: 0.5)) {
        guard let loc = location(of: id), tracks[loc.track].isMain, loc.clip > 0 else { return }
        tracks[loc.track].clips[loc.clip].transitionIn = type.map { Transition(type: $0, duration: duration) }
    }

    /// Applique la même transition à tous les raccords de la piste principale.
    mutating func setTransitionEverywhere(_ type: String?, duration: RTime = RTime(seconds: 0.5)) {
        guard let mi = mainTrackIndex else { return }
        for ci in tracks[mi].clips.indices where ci > 0 {
            tracks[mi].clips[ci].transitionIn = type.map { Transition(type: $0, duration: duration) }
        }
    }

    // MARK: - Marqueurs

    @discardableResult
    mutating func addMarker(at time: RTime) -> UUID {
        let t = time.snapped(fps: settings.frameRate)
        if let existing = markers.first(where: { $0.time == t }) { return existing.id }
        let marker = Marker(time: t, name: "Marqueur \(markers.count + 1)")
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        return marker.id
    }

    // MARK: - Normalisation

    /// Remet le projet dans un état cohérent après chaque commande.
    mutating func normalize(magnetic: Bool) {
        ensureMainTrack()
        let minimum = RTime.frame(fps: settings.frameRate)
        for ti in tracks.indices {
            tracks[ti].clips.removeAll { $0.duration < minimum }
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].start < .zero {
                tracks[ti].clips[ci].start = .zero
            }
            tracks[ti].clips.sort { $0.start < $1.start }
        }
        if magnetic { packMainTrack() }
        // Les pistes vides (sauf la principale) disparaissent.
        tracks.removeAll { !$0.isMain && $0.clips.isEmpty }
        // Les liens vers des clips disparus sont retirés.
        let ids = Set(tracks.flatMap(\.clips).map(\.id))
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices {
                tracks[ti].clips[ci].linkedClipIDs.removeAll { !ids.contains($0) }
            }
        }
    }

    /// Piste principale magnétique : les clips se suivent sans vide à partir de 0.
    mutating func packMainTrack() {
        guard let mi = mainTrackIndex else { return }
        let clips = tracks[mi].clips.sorted { $0.start < $1.start }
        var originals: [UUID: RTime] = [:]
        for c in clips { originals[c.id] = c.start }
        layoutMainTrack(clips, originalStarts: originals)
    }

    /// Range les clips de la piste principale dans l'ordre donné, bout à bout.
    /// Le son détaché suit chaque clip du même décalage que lui.
    private mutating func layoutMainTrack(_ ordered: [Clip], originalStarts: [UUID: RTime]) {
        guard let mi = mainTrackIndex else { return }
        var clips = ordered
        var cursor = RTime.zero
        let minimum = RTime.frame(fps: settings.frameRate)
        for i in clips.indices {
            // Transition : le clip commence avant la fin du précédent (chevauchement).
            var overlap = RTime.zero
            if i == 0 {
                clips[i].transitionIn = nil
            } else if var t = clips[i].transitionIn {
                let limit = RTime(ticks: min(clips[i - 1].duration.ticks, clips[i].duration.ticks) / 2)
                t.duration = max(minimum, min(t.duration, limit)).snapped(fps: settings.frameRate)
                clips[i].transitionIn = t
                overlap = t.duration
            }
            cursor = max(.zero, cursor - overlap)
            if let original = originalStarts[clips[i].id] {
                let delta = cursor - original
                if delta != .zero {
                    for linked in clips[i].linkedClipIDs {
                        if let l = location(of: linked), l.track != mi {
                            tracks[l.track].clips[l.clip].start = max(.zero, tracks[l.track].clips[l.clip].start + delta)
                        }
                    }
                }
            }
            clips[i].start = cursor
            cursor = clips[i].end
        }
        tracks[mi].clips = clips
    }
}
