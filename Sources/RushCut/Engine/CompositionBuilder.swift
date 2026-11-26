import Foundation
import AVFoundation

/// Résultat de la traduction du projet en objets AVFoundation, identique pour l'aperçu et l'export.
struct BuiltComposition {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    /// Durée du contenu (0 pour un projet vide).
    let contentDuration: RTime
    /// Durée de la composition (au moins une image).
    let duration: RTime
    let hasAudio: Bool
    /// Algorithme de hauteur du son quand la vitesse change.
    let pitchAlgorithm: AVAudioTimePitchAlgorithm
}

/// Un morceau de son placé sur une piste audio de la composition (pour le volume et le traitement).
struct AudioSegment {
    var clip: Clip
    /// Début et fin réels dans la composition.
    var start: RTime
    var end: RTime
    /// Fondus effectifs (y compris le fondu croisé d'une transition).
    var fadeIn: RTime
    var fadeOut: RTime
}

enum CompositionBuilder {
    /// Construit la composition du projet.
    static func build(project: Project, renderSize: CGSize? = nil, frameRate: Int? = nil,
                      resolve: (MediaRef) -> URL? = MediaResolver.url(for:)) async throws -> BuiltComposition {
        let fps = frameRate ?? project.settings.frameRate
        let composition = AVMutableComposition()
        let contentDuration = project.duration
        let duration = max(contentDuration, RTime.frame(fps: fps))

        // Piste de fond : garantit la durée et l'appel du compositeur.
        let blank = try await BlankVideo.shared.get()
        guard let blankTrack = try await blank.loadTracks(withMediaType: .video).first,
              let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RushError.render("piste de fond indisponible")
        }
        let oneSecond = CMTime(value: 1, timescale: 1)
        try base.insertTimeRange(CMTimeRange(start: .zero, duration: oneSecond), of: blankTrack, at: .zero)
        base.scaleTimeRange(CMTimeRange(start: .zero, duration: oneSecond), toDuration: duration.cmTime)

        var videoTrackIDs: [CMPersistentTrackID] = [base.trackID]
        var layers: [LayerPlan] = []
        var audioGroups: [(AVMutableCompositionTrack, [AudioSegment])] = []
        var varispeed = false

        func newVideoTrack() -> AVMutableCompositionTrack? {
            let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            if let id = t?.trackID { videoTrackIDs.append(id) }
            return t
        }
        func newAudioTrack() -> AVMutableCompositionTrack? {
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        /// Insère la source d'un clip à sa place, à la bonne vitesse. Renvoie la durée réellement placée.
        func insert(_ source: AVAssetTrack, clip: Clip, assetDuration: RTime, into track: AVMutableCompositionTrack) -> RTime? {
            let rate = max(0.01, clip.speed.rate)
            let available = assetDuration - clip.sourceIn
            let sourceLength = min(clip.sourceLength, available)
            guard sourceLength > .zero else { return nil }
            do {
                try track.insertTimeRange(CMTimeRange(start: clip.sourceIn.cmTime, duration: sourceLength.cmTime), of: source, at: clip.start.cmTime)
            } catch {
                Log.error("Insertion impossible (\(clip.name)) : \(error.localizedDescription)")
                return nil
            }
            let placed = RTime(ticks: Int64(Double(sourceLength.ticks) / rate))
            if abs(rate - 1) > 0.0001 {
                track.scaleTimeRange(CMTimeRange(start: clip.start.cmTime, duration: sourceLength.cmTime), toDuration: placed.cmTime)
            }
            return placed
        }

        for (trackIndex, track) in project.tracks.enumerated() {
            if track.kind.isVisual {
                // La piste principale alterne deux pistes de composition pour que les transitions se chevauchent.
                var videoTracks: [AVMutableCompositionTrack] = []
                var audioTracks: [(AVMutableCompositionTrack, [AudioSegment])] = []
                let lanes = track.isMain ? 2 : 1

                for (clipIndex, clip) in track.clips.enumerated() {
                    var layer = LayerPlan(clip: clip, trackIndex: trackIndex, content: .missing(name: clip.name),
                                          isMain: track.isMain, isHidden: track.isHidden)
                    if let text = clip.text {
                        layer.content = .text(text)
                        layers.append(layer)
                        continue
                    }
                    if let sticker = clip.sticker {
                        layer.content = .sticker(id: sticker, color: clip.stickerColor)
                        layers.append(layer)
                        continue
                    }
                    if clip.isEffectOnly {
                        layer.content = .effect
                        layers.append(layer)
                        continue
                    }
                    guard let media = project.media(clip.mediaID) else { continue }
                    guard let url = resolve(media) else {
                        layers.append(layer)
                        continue
                    }
                    switch media.kind {
                    case .image:
                        layer.content = .image(url: url, animated: media.isAnimated)
                        layers.append(layer)
                    case .video:
                        let asset = AssetCache.shared.asset(for: url)
                        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
                            layers.append(layer)
                            continue
                        }
                        let assetDuration = RTime((try? await asset.load(.duration)) ?? .zero)
                        let lane = clipIndex % lanes
                        while videoTracks.count <= lane { if let t = newVideoTrack() { videoTracks.append(t) } else { break } }
                        guard videoTracks.indices.contains(lane),
                              let placed = insert(sourceVideo, clip: clip, assetDuration: assetDuration, into: videoTracks[lane]) else { continue }
                        let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
                        layer.content = .video(trackID: videoTracks[lane].trackID, orientation: CGImagePropertyOrientation(preferredTransform: transform))
                        layers.append(layer)
                        if abs(clip.speed.rate - 1) > 0.0001 && !clip.speed.preservePitch { varispeed = true }

                        // Son de la vidéo (sauf s'il a été détaché ou coupé).
                        if media.hasAudio, !clip.audio.isMuted, !track.isMuted,
                           let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                            while audioTracks.count <= lane { if let t = newAudioTrack() { audioTracks.append((t, [])) } else { break } }
                            guard audioTracks.indices.contains(lane),
                                  insert(sourceAudio, clip: clip, assetDuration: assetDuration, into: audioTracks[lane].0) != nil else { continue }
                            var fadeIn = clip.audio.fadeIn, fadeOut = clip.audio.fadeOut
                            if let t = clip.transitionIn { fadeIn = max(fadeIn, t.duration) }
                            if track.isMain, clipIndex + 1 < track.clips.count, let next = track.clips[clipIndex + 1].transitionIn {
                                fadeOut = max(fadeOut, next.duration)
                            }
                            audioTracks[lane].1.append(AudioSegment(clip: clip, start: clip.start, end: clip.start + placed, fadeIn: fadeIn, fadeOut: fadeOut))
                        }
                    case .audio:
                        continue
                    }
                }
                audioGroups.append(contentsOf: audioTracks)
            } else {
                // Piste audio.
                guard !track.isMuted else { continue }
                var audioTrack: AVMutableCompositionTrack?
                var segments: [AudioSegment] = []
                for clip in track.clips {
                    guard let media = project.media(clip.mediaID), media.kind == .audio || media.hasAudio,
                          let url = resolve(media) else { continue }
                    let asset = AssetCache.shared.asset(for: url)
                    guard let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                    let assetDuration = RTime((try? await asset.load(.duration)) ?? .zero)
                    if audioTrack == nil { audioTrack = newAudioTrack() }
                    guard let at = audioTrack, let placed = insert(sourceAudio, clip: clip, assetDuration: assetDuration, into: at) else { continue }
                    if abs(clip.speed.rate - 1) > 0.0001 && !clip.speed.preservePitch { varispeed = true }
                    segments.append(AudioSegment(clip: clip, start: clip.start, end: clip.start + placed, fadeIn: clip.audio.fadeIn, fadeOut: clip.audio.fadeOut))
                }
                if let at = audioTrack { audioGroups.append((at, segments)) }
            }
        }

        let plan = RenderPlan(background: project.settings.backgroundColor,
                              blurBackground: project.settings.backgroundMode == .blur,
                              layers: layers, fps: fps)
        let size = renderSize ?? project.settings.canvasSize
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = RushCompositor.self
        videoComposition.renderSize = CGSize(width: max(16, size.width.rounded()), height: max(16, size.height.rounded()))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.instructions = [
            RushInstruction(timeRange: CMTimeRange(start: .zero, duration: duration.cmTime), trackIDs: videoTrackIDs, plan: plan),
        ]

        var parameters: [AVMutableAudioMixInputParameters] = []
        for (track, segments) in audioGroups where !segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: track)
            for segment in segments { applyVolume(p, segment: segment) }
            AudioProcessing.attach(to: p, segments: segments)
            parameters.append(p)
        }
        var mix: AVMutableAudioMix?
        if !parameters.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = parameters
            mix = m
        }
        return BuiltComposition(asset: composition.copy() as! AVComposition,
                                videoComposition: videoComposition.copy() as! AVVideoComposition,
                                audioMix: mix?.copy() as? AVAudioMix,
                                contentDuration: contentDuration,
                                duration: duration,
                                hasAudio: !parameters.isEmpty,
                                pitchAlgorithm: varispeed ? .varispeed : .spectral)
    }

    /// Gain (0–1) d'un morceau de son à un instant : volume (avec images clés) et fondus.
    /// Au-delà de 0 dB, le gain supplémentaire est appliqué par le traitement audio.
    static func gain(_ segment: AudioSegment, at time: RTime) -> Float {
        let clip = segment.clip
        let local = time - clip.start
        let db = clip.value(.volume, at: local)
        var g: Double = db <= AudioSettings.silenceDB ? 0 : min(1, pow(10, db / 20))
        let length = segment.end - segment.start
        if segment.fadeIn > .zero, local < segment.fadeIn {
            g *= Double(max(0, local.ticks)) / Double(max(1, segment.fadeIn.ticks))
        }
        let fromEnd = length - local
        if segment.fadeOut > .zero, fromEnd < segment.fadeOut {
            g *= Double(max(0, fromEnd.ticks)) / Double(max(1, segment.fadeOut.ticks))
        }
        return Float(max(0, min(1, g)))
    }

    /// Enveloppe de volume d'un morceau : rampes successives (dans l'ordre chronologique).
    static func applyVolume(_ params: AVMutableAudioMixInputParameters, segment: AudioSegment) {
        let length = segment.end - segment.start
        guard length > .zero else { return }
        let simple = !segment.clip.hasKeyframes(.volume)
        if simple && segment.fadeIn == .zero && segment.fadeOut == .zero {
            params.setVolume(gain(segment, at: segment.start), at: segment.start.cmTime)
            return
        }
        // Pas de 1/20 s au plus (plus fin pour les clips courts).
        let step = RTime(ticks: max(RTime.timescale / 100, min(RTime.timescale / 20, length.ticks / 400)))
        var t = segment.start
        while t < segment.end {
            let next = min(segment.end, t + step)
            let a = gain(segment, at: t), b = gain(segment, at: next)
            params.setVolumeRamp(fromStartVolume: a, toEndVolume: b, timeRange: CMTimeRange(start: t.cmTime, end: next.cmTime))
            t = next
        }
    }
}
