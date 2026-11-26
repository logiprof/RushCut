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
}

enum CompositionBuilder {
    /// Construit la composition du projet.
    /// - Parameters:
    ///   - renderSize: taille de rendu (par défaut celle du projet).
    ///   - frameRate: fréquence d'images (par défaut celle du projet).
    ///   - resolve: retrouve le fichier d'un média (nil s'il est introuvable).
    static func build(project: Project, renderSize: CGSize? = nil, frameRate: Int? = nil,
                      resolve: (MediaRef) -> URL? = MediaResolver.url(for:)) async throws -> BuiltComposition {
        let fps = frameRate ?? project.settings.frameRate
        let composition = AVMutableComposition()
        let contentDuration = project.duration
        let duration = max(contentDuration, RTime.frame(fps: fps))

        // Piste de fond.
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
        var audioParameters: [AVMutableAudioMixInputParameters] = []

        for track in project.tracks {
            if track.kind.isVisual {
                var videoTrack: AVMutableCompositionTrack?
                var audioTrack: AVMutableCompositionTrack?
                var audioParams: AVMutableAudioMixInputParameters?

                for clip in track.clips {
                    var layer = LayerPlan(clipID: clip.id, start: clip.start, end: clip.end, sourceIn: clip.sourceIn,
                                          content: .missing(name: clip.name), transform: clip.transform, crop: clip.crop,
                                          fit: clip.fit, opacity: clip.opacity, isMain: track.isMain, isHidden: track.isHidden)
                    if let text = clip.text {
                        layer.content = .text(text)
                        layer.fit = .none
                        layers.append(layer)
                        continue
                    }
                    guard let media = project.media(clip.mediaID) else { continue }
                    guard let url = resolve(media) else {
                        layer.content = .missing(name: media.name)
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
                            layer.content = .missing(name: media.name)
                            layers.append(layer)
                            continue
                        }
                        let assetDuration = RTime((try? await asset.load(.duration)) ?? .zero)
                        let available = assetDuration - clip.sourceIn
                        let insertDuration = min(clip.duration, available)
                        guard insertDuration > .zero else { continue }
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                            if let id = videoTrack?.trackID { videoTrackIDs.append(id) }
                        }
                        guard let vt = videoTrack else { continue }
                        let range = CMTimeRange(start: clip.sourceIn.cmTime, duration: insertDuration.cmTime)
                        do {
                            try vt.insertTimeRange(range, of: sourceVideo, at: clip.start.cmTime)
                        } catch {
                            Log.error("Insertion vidéo impossible (\(media.name)) : \(error.localizedDescription)")
                            continue
                        }
                        let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
                        layer.content = .video(trackID: vt.trackID, orientation: CGImagePropertyOrientation(preferredTransform: transform))
                        layers.append(layer)

                        // Son de la vidéo (sauf s'il a été détaché ou coupé).
                        if media.hasAudio, !clip.audio.isMuted, !track.isMuted,
                           let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                            if audioTrack == nil {
                                audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                                if let at = audioTrack {
                                    let p = AVMutableAudioMixInputParameters(track: at)
                                    audioParams = p
                                    audioParameters.append(p)
                                }
                            }
                            if let at = audioTrack, let p = audioParams {
                                do {
                                    try at.insertTimeRange(range, of: sourceAudio, at: clip.start.cmTime)
                                    applyVolume(p, clip: clip, duration: insertDuration)
                                } catch {
                                    Log.error("Insertion audio impossible (\(media.name)) : \(error.localizedDescription)")
                                }
                            }
                        }
                    case .audio:
                        continue
                    }
                }
            } else {
                // Piste audio.
                guard !track.isMuted else { continue }
                var audioTrack: AVMutableCompositionTrack?
                var audioParams: AVMutableAudioMixInputParameters?
                for clip in track.clips {
                    guard let media = project.media(clip.mediaID), media.kind == .audio || media.hasAudio,
                          let url = resolve(media) else { continue }
                    let asset = AssetCache.shared.asset(for: url)
                    guard let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                    let assetDuration = RTime((try? await asset.load(.duration)) ?? .zero)
                    let insertDuration = min(clip.duration, assetDuration - clip.sourceIn)
                    guard insertDuration > .zero else { continue }
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        if let at = audioTrack {
                            let p = AVMutableAudioMixInputParameters(track: at)
                            audioParams = p
                            audioParameters.append(p)
                        }
                    }
                    guard let at = audioTrack, let p = audioParams else { continue }
                    do {
                        try at.insertTimeRange(CMTimeRange(start: clip.sourceIn.cmTime, duration: insertDuration.cmTime),
                                               of: sourceAudio, at: clip.start.cmTime)
                        applyVolume(p, clip: clip, duration: insertDuration)
                    } catch {
                        Log.error("Insertion audio impossible (\(media.name)) : \(error.localizedDescription)")
                    }
                }
            }
        }

        let plan = RenderPlan(background: project.settings.backgroundColor,
                              blurBackground: project.settings.backgroundMode == .blur,
                              layers: layers)
        let size = renderSize ?? project.settings.canvasSize
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = RushCompositor.self
        videoComposition.renderSize = CGSize(width: max(16, size.width.rounded()), height: max(16, size.height.rounded()))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.instructions = [
            RushInstruction(timeRange: CMTimeRange(start: .zero, duration: duration.cmTime),
                            trackIDs: videoTrackIDs, plan: plan),
        ]

        var mix: AVMutableAudioMix?
        if !audioParameters.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = audioParameters
            mix = m
        }
        return BuiltComposition(asset: composition.copy() as! AVComposition,
                                videoComposition: videoComposition.copy() as! AVVideoComposition,
                                audioMix: mix?.copy() as? AVAudioMix,
                                contentDuration: contentDuration,
                                duration: duration,
                                hasAudio: !audioParameters.isEmpty)
    }

    /// Volume et fondus d'un clip. Les réglages doivent être ajoutés dans l'ordre chronologique.
    static func applyVolume(_ params: AVMutableAudioMixInputParameters, clip: Clip, duration: RTime) {
        let volume = clip.audio.linearGain
        let start = clip.start
        let end = clip.start + duration
        let fadeIn = min(clip.audio.fadeIn, duration)
        let fadeOut = min(clip.audio.fadeOut, duration - fadeIn)
        if fadeIn > .zero {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                 timeRange: CMTimeRange(start: start.cmTime, duration: fadeIn.cmTime))
        } else {
            params.setVolume(volume, at: start.cmTime)
        }
        if fadeOut > .zero {
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: (end - fadeOut).cmTime, duration: fadeOut.cmTime))
        }
    }
}
