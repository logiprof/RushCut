import Foundation
import AVFoundation
import CoreImage

/// Actions du lot V1 : effets, filtres, transitions, autocollants, vitesse, images clés, attributs.
extension EditorModel {
    /// Clips sélectionnés qui affichent une image (vidéo, photo, texte, autocollant).
    var visualSelection: [Clip] {
        selection.compactMap { id in
            guard let loc = project.location(of: id) else { return nil }
            let track = project.tracks[loc.track]
            let clip = track.clips[loc.clip]
            guard track.kind.isVisual, !clip.isEffectOnly else { return nil }
            if clip.isText || clip.isSticker { return clip }
            return project.media(clip.mediaID)?.hasVideo == true ? clip : nil
        }
    }

    /// Instant de la tête de lecture dans le clip, ou nil si elle est en dehors.
    func localTime(in clip: Clip) -> RTime? {
        let t = playhead
        guard t >= clip.start, t <= clip.end else { return nil }
        return min(max(.zero, t - clip.start), clip.duration)
    }

    // MARK: Effets

    /// Applique l'effet aux clips sélectionnés, ou l'ajoute sur une piste d'effets s'il n'y a pas de sélection.
    func useEffect(_ def: EffectDef) {
        let targets = visualSelection
        if targets.isEmpty {
            addEffectClip(def)
        } else {
            apply("Effet « \(def.name) »") { p in
                for c in targets { p.updateClip(c.id) { $0.effects.append(EffectInstance(type: def.id)) } }
            }
        }
    }

    func addEffectClip(_ def: EffectDef) {
        var created: UUID?
        let t = playhead
        apply("Ajouter l'effet « \(def.name) »") { created = $0.addEffectClip(def.id, name: def.name, at: t) }
        if let created { selection = [created] }
    }

    func removeEffect(_ effectID: UUID, from clipID: UUID) {
        updateClip(clipID, "Retirer l'effet") { $0.effects.removeAll { $0.id == effectID } }
    }

    // MARK: Filtres

    func useFilter(_ def: FilterDef) {
        let targets = visualSelection
        if targets.isEmpty {
            var created: UUID?
            let t = playhead
            apply("Ajouter le filtre « \(def.name) »") { created = $0.addFilterClip(def.id, name: def.name, at: t) }
            if let created { selection = [created] }
        } else {
            apply("Filtre « \(def.name) »") { p in
                for c in targets {
                    p.updateClip(c.id) { clip in
                        let intensity = clip.filter?.intensity ?? 1
                        clip.filter = FilterRef(id: def.id, intensity: intensity)
                    }
                }
            }
        }
    }

    // MARK: Transitions

    /// Clip de la piste principale qui recevra la transition : le clip sélectionné, sinon le raccord le plus proche.
    var transitionTarget: Clip? {
        guard let mi = project.mainTrackIndex else { return nil }
        let clips = project.tracks[mi].clips
        guard clips.count > 1 else { return nil }
        if let sel = singleSelection, let i = clips.firstIndex(where: { $0.id == sel.id }) {
            return clips[max(1, i)]
        }
        let t = playhead
        return clips.dropFirst().min { abs(($0.start - t).seconds) < abs(($1.start - t).seconds) }
    }

    func useTransition(_ def: TransitionDef?) {
        guard let target = transitionTarget else { return }
        let duration = target.transitionIn?.duration ?? RTime(seconds: 0.5)
        apply(def.map { "Transition « \($0.name) »" } ?? "Retirer la transition") { $0.setTransition(def?.id, on: target.id, duration: duration) }
        selection = [target.id]
    }

    func useTransitionEverywhere(_ type: String?, duration: RTime) {
        apply("Transition sur tous les raccords") { $0.setTransitionEverywhere(type, duration: duration) }
    }

    func setTransitionDuration(_ clipID: UUID, seconds: Double) {
        apply("Durée de la transition", coalesce: "transitionD") { p in
            guard let loc = p.location(of: clipID), let tr = p.tracks[loc.track].clips[loc.clip].transitionIn else { return }
            p.setTransition(tr.type, on: clipID, duration: RTime(seconds: seconds).snapped(fps: p.settings.frameRate))
        }
    }

    // MARK: Autocollants et textes

    func addSticker(_ def: StickerDef, color: RGBA = RGBA(r: 1, g: 0.85, b: 0.1)) {
        var created: UUID?
        let t = playhead
        apply("Ajouter l'autocollant « \(def.name) »") { created = $0.addSticker(def.id, name: def.name, color: color, at: t) }
        if let created { selection = [created] }
    }

    // MARK: Vitesse

    func setSpeed(_ clipID: UUID, rate: Double) {
        apply("Vitesse", coalesce: "vitesse") { $0.setSpeed(clipID, rate: rate) }
    }

    // MARK: Images clés

    func toggleKeyframe(_ prop: KeyProp, clipID: UUID) {
        guard let clip = project.clip(clipID), let local = localTime(in: clip) else { return }
        let fps = self.fps
        updateClip(clipID, "Image clé") { $0.toggleKeyframe(prop, at: local, fps: fps) }
    }

    func setKeyframed(_ prop: KeyProp, _ value: Double, clipID: UUID, name: String, coalesce: String) {
        guard let clip = project.clip(clipID) else { return }
        let local = localTime(in: clip)
        let fps = self.fps
        updateClip(clipID, name, coalesce: coalesce) { $0.set(prop, value, at: local, fps: fps) }
    }

    func setInterpolation(_ prop: KeyProp, _ mode: Interpolation, clipID: UUID) {
        guard let clip = project.clip(clipID), let local = localTime(in: clip),
              let i = clip.keyframeIndex(prop, near: local, fps: fps) else { return }
        updateClip(clipID, "Interpolation") { $0.keyframes[prop.rawValue]?[i].interpolation = mode }
    }

    /// Va à l'image clé précédente ou suivante (tous paramètres confondus).
    func jumpToKeyframe(clipID: UUID, forward: Bool) {
        guard let clip = project.clip(clipID) else { return }
        let times = clip.keyframes.values.flatMap { $0.map { clip.start + $0.time } }.sorted()
        let t = playhead
        let eps = RTime.frame(fps: fps)
        let target = forward ? times.first { $0 > t + eps * 0.5 } : times.last { $0 < t - eps * 0.5 }
        if let target { playback.seek(to: target) }
    }

    // MARK: Attributs

    func copyAttributes() {
        guard let clip = singleSelection else { return }
        attributeClipboard = clip
    }

    func pasteAttributes() {
        guard let source = attributeClipboard else { return }
        let ids = Array(selection)
        apply("Coller les attributs") { p in
            for id in ids where id != source.id {
                p.updateClip(id) { c in
                    c.effects = source.effects.map { var e = $0; e.id = UUID(); return e }
                    c.filter = source.filter
                    c.adjust = source.adjust
                    c.style = source.style
                    c.chroma = source.chroma
                    c.mask = source.mask
                    c.blendMode = source.blendMode
                    c.opacity = source.opacity
                    c.transform = source.transform
                    c.animIn = source.animIn
                    c.animOut = source.animOut
                    c.animLoop = source.animLoop
                    c.audio.volumeDB = source.audio.volumeDB
                    if var t = c.text, let s = source.text {
                        let string = t.string, words = t.words
                        t = s
                        t.string = string
                        t.words = words
                        c.text = t
                    }
                }
            }
        }
    }

    // MARK: Ajustement automatique

    /// Analyse l'image du clip sous la tête de lecture et règle les ajustements.
    func autoEnhance(_ clipID: UUID) {
        guard let clip = project.clip(clipID), let media = project.media(clip.mediaID),
              let url = MediaResolver.url(for: media) else { return }
        let local = (localTime(in: clip) ?? .zero).seconds
        let sourceTime = clip.sourceIn.seconds + local * clip.speed.rate
        let kind = media.kind
        Task {
            let image: CIImage?
            if kind == .image {
                image = CIImage(contentsOf: url)
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 640)
                let cg = try? await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image
                image = cg.map { CIImage(cgImage: $0) }
            }
            guard let image else { return }
            let adjust = ColorPipeline.autoAdjust(for: image)
            self.updateClip(clipID, "Ajustement automatique") { $0.adjust = adjust }
        }
    }
}
