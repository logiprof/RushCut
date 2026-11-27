import Foundation

/// Vu-mètre de la lecture, calculé à partir des formes d'onde déjà analysées (aucun traitement sur le son lui-même).
@MainActor
enum AudioMeter {
    private static var held: Float = 0
    private static var lastTime = Date()

    /// Niveau crête (0–1, au-delà = saturation) à la tête de lecture.
    static func level(project: Project, waveforms: [UUID: [Float]], at time: RTime, playing: Bool) -> Float {
        let now = Date()
        let elapsed = Float(now.timeIntervalSince(lastTime))
        lastTime = now
        guard playing else {
            held = max(0, held - elapsed * 2)
            return held
        }
        var power: Float = 0
        for track in project.tracks where !track.isMuted {
            for clip in track.clips where clip.contains(time) && !clip.audio.isMuted {
                guard let media = project.media(clip.mediaID), media.hasAudio || media.kind == .audio,
                      let peaks = waveforms[media.id], !peaks.isEmpty else { continue }
                if track.kind.isVisual && media.kind == .audio { continue }
                let local = time - clip.start
                let source = clip.sourceIn.seconds + local.seconds * clip.speed.rate
                let index = min(peaks.count - 1, max(0, Int(source * Double(MediaPreviews.peaksPerSecond))))
                let db = clip.value(.volume, at: local)
                var gain: Float = db <= AudioSettings.silenceDB ? 0 : Float(pow(10, db / 20))
                if clip.audio.fadeIn > .zero, local < clip.audio.fadeIn { gain *= Float(local.seconds / clip.audio.fadeIn.seconds) }
                let fromEnd = clip.duration - local
                if clip.audio.fadeOut > .zero, fromEnd < clip.audio.fadeOut { gain *= Float(fromEnd.seconds / clip.audio.fadeOut.seconds) }
                let v = peaks[index] * gain
                power += v * v
            }
        }
        let instant = sqrt(power)
        held = instant > held ? instant : max(instant, held - elapsed * 1.5)
        return held
    }
}
