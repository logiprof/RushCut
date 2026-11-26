import Foundation
import AVFoundation
import Combine

/// Lecture : AVPlayer + tête de lecture synchronisée, lecture J/K/L, image par image.
@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published var currentTime: RTime = .zero
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: RTime = .zero

    var fps: Int = 30
    private var shuttleRate: Float = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var seekInProgress = false
    private var pendingSeek: RTime?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                let t = RTime(time)
                self.currentTime = t
                if self.shuttleRate < 0 && t <= .zero { self.pause() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.shuttleRate = 0
                self.currentTime = self.duration
            }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    /// Remplace la composition (après chaque modification) sans perdre la position.
    func load(_ built: BuiltComposition) {
        let item = AVPlayerItem(asset: built.asset)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        let wasPlaying = isPlaying
        let rate = player.rate
        player.replaceCurrentItem(with: item)
        duration = built.contentDuration
        let target = min(currentTime, built.duration)
        currentTime = target
        player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.rate = rate == 0 ? 1 : rate }
    }

    /// Applique de nouveaux réglages visuels ou de volume sans recharger la vidéo.
    func update(_ built: BuiltComposition) {
        guard let item = player.currentItem else { load(built); return }
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        if !isPlaying {
            player.seek(to: currentTime.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard duration > .zero else { return }
        if currentTime >= duration - RTime.frame(fps: fps) {
            seek(to: .zero)
        }
        shuttleRate = 1
        player.rate = 1
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        shuttleRate = 0
        currentTime = RTime(player.currentTime()).snapped(fps: fps)
    }

    /// Recherche précise à l'image près ; les recherches rapprochées (glisser) sont regroupées.
    func seek(to time: RTime) {
        let target = min(max(.zero, time), max(duration, .zero)).snapped(fps: fps)
        currentTime = target
        if isPlaying { player.pause(); isPlaying = false; shuttleRate = 0 }
        if seekInProgress {
            pendingSeek = target
            return
        }
        seekInProgress = true
        player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInProgress = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next)
                }
            }
        }
    }

    func step(frames: Int) {
        let delta = RTime(ticks: RTime.ticksPerFrame(fps: fps) * Int64(frames))
        if isPlaying { pause() }
        seek(to: currentTime + delta)
    }

    /// J (−1), K (0), L (+1) : chaque appui répété double la vitesse jusqu'à 4×.
    func shuttle(_ direction: Int) {
        if direction == 0 { pause(); return }
        let sign: Float = direction > 0 ? 1 : -1
        if shuttleRate != 0 && (shuttleRate > 0) == (sign > 0) {
            shuttleRate = sign * min(abs(shuttleRate) * 2, 4)
        } else {
            shuttleRate = sign
        }
        if sign < 0, let item = player.currentItem, !item.canPlayReverse {
            // Lecture arrière non disponible : recul d'une seconde par appui.
            seek(to: currentTime - RTime(seconds: Double(abs(shuttleRate))))
            shuttleRate = 0
            return
        }
        if sign > 0 && currentTime >= duration { seek(to: .zero) }
        player.rate = shuttleRate
        isPlaying = true
    }
}
