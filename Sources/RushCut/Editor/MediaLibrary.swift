import Foundation
import AppKit

/// Aperçus des médias du projet (vignettes, bandes de miniatures, formes d'onde), calculés en arrière-plan.
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var posters: [UUID: CGImage] = [:]
    @Published private(set) var strips: [UUID: (images: [CGImage], interval: Double)] = [:]
    @Published private(set) var waveforms: [UUID: [Float]] = [:]
    @Published private(set) var missing: Set<UUID> = []

    private var started: Set<String> = []
    private var tasks: [Task<Void, Never>] = []

    func sync(with media: [MediaRef]) {
        var nowMissing = Set<UUID>()
        for m in media {
            guard let url = MediaResolver.url(for: m) else {
                nowMissing.insert(m.id)
                continue
            }
            let key = "\(m.id.uuidString)|\(url.path)"
            guard !started.contains(key) else { continue }
            started.insert(key)
            load(m, url: url)
        }
        if nowMissing != missing { missing = nowMissing }
    }

    private func load(_ media: MediaRef, url: URL) {
        let id = media.id
        let task = Task { [weak self] in
            if media.kind != .audio, let poster = await MediaPreviews.poster(for: media, url: url) {
                self?.posters[id] = poster
            }
            if media.kind == .image, let poster = self?.posters[id] {
                self?.strips[id] = ([poster], max(media.duration.seconds, 1))
            }
            if media.hasAudio || media.kind == .audio {
                let peaks = await Task.detached(priority: .utility) { await MediaPreviews.waveform(url: url) }.value
                self?.waveforms[id] = peaks
            }
            if media.kind == .video {
                let strip = await MediaPreviews.strip(for: media, url: url)
                if !strip.images.isEmpty { self?.strips[id] = strip }
            }
        }
        tasks.append(task)
    }

    func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func poster(_ id: UUID?) -> CGImage? {
        guard let id else { return nil }
        return posters[id]
    }
}
