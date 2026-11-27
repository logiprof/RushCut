import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

enum ExportKind: String, CaseIterable, Identifiable {
    case video, gif, audio, still
    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: return "Vidéo"
        case .gif: return "GIF animé"
        case .audio: return "Son seul (.m4a)"
        case .still: return "Image (.png)"
        }
    }
    var fileExtension: String {
        switch self {
        case .video: return "mp4"
        case .gif: return "gif"
        case .audio: return "m4a"
        case .still: return "png"
        }
    }
}

/// Exports autres que la vidéo : GIF, son seul, image fixe.
enum ExtraExporters {
    /// GIF animé (largeur max 640 px par défaut, 15 images/s), en boucle.
    static func gif(project: Project, destination: URL, maxWidth: CGFloat = 640, fps: Int = 15,
                    start: RTime? = nil, end: RTime? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let size = fitted(project.settings.canvasSize, maxWidth: maxWidth)
        let built = try await CompositionBuilder.build(project: project, renderSize: size, frameRate: fps)
        let from = start ?? .zero, to = min(end ?? built.duration, built.duration)
        guard to > from else { throw RushError.exportFailed("la plage à exporter est vide.") }
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = size
        let count = max(1, Int(((to - from).seconds * Double(fps)).rounded()))
        guard count <= 1500 else { throw RushError.exportFailed("un GIF est limité à 100 secondes à 15 images par seconde. Réduisez la plage avec les points d'entrée et de sortie (I et O).") }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".rushcut-\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw RushError.exportFailed("création du GIF impossible")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let t = from + RTime(seconds: Double(i) / Double(fps))
            let image = try await generator.image(at: t.cmTime).image
            CGImageDestinationAddImage(dest, image, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw RushError.exportFailed("écriture du GIF impossible") }
        try replace(destination, with: temp)
    }

    /// Son seul, mixé comme dans la vidéo (AAC, .m4a).
    static func audio(project: Project, destination: URL, start: RTime? = nil, end: RTime? = nil) async throws {
        await AudioPreprocessor.prepare(project)
        let built = try await CompositionBuilder.build(project: project, renderSize: CGSize(width: 320, height: 180))
        guard built.hasAudio else { throw RushError.exportFailed("le projet ne contient aucun son.") }
        guard let session = AVAssetExportSession(asset: built.asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RushError.exportFailed("export du son indisponible")
        }
        session.audioMix = built.audioMix
        let from = start ?? .zero, to = min(end ?? built.duration, built.duration)
        session.timeRange = CMTimeRange(start: from.cmTime, end: to.cmTime)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".rushcut-\(UUID().uuidString).m4a")
        try await session.export(to: temp, as: .m4a)
        try replace(destination, with: temp)
    }

    /// Image de la tête de lecture, à la taille choisie.
    static func still(project: Project, at time: RTime, size: CGSize, destination: URL) async throws {
        let built = try await CompositionBuilder.build(project: project, renderSize: size)
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = size
        let t = min(time, max(.zero, built.duration - RTime.frame(fps: project.settings.frameRate)))
        let image = try await generator.image(at: t.cmTime).image
        try writePNG(image, to: destination)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RushError.exportFailed("écriture de l'image impossible")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RushError.exportFailed("écriture de l'image impossible") }
    }

    static func fitted(_ canvas: CGSize, maxWidth: CGFloat) -> CGSize {
        let scale = min(1, maxWidth / max(canvas.width, canvas.height))
        return CGSize(width: max(16, (canvas.width * scale / 2).rounded() * 2), height: max(16, (canvas.height * scale / 2).rounded() * 2))
    }

    private static func replace(_ destination: URL, with temp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: destination) }
    }
}

/// File d'exports en arrière-plan : on continue à monter pendant que les exports s'enchaînent.
@MainActor
final class ExportQueue: ObservableObject {
    static let shared = ExportQueue()

    struct Job: Identifiable {
        enum State: Equatable { case waiting, running(Double), done, failed(String), cancelled }
        let id = UUID()
        let name: String
        let destination: URL
        var state: State = .waiting
        let work: (Exporter, @escaping @Sendable (Double) -> Void) async throws -> Void
        let exporter = Exporter()
    }

    @Published private(set) var jobs: [Job] = []
    private var running = false

    var activeCount: Int { jobs.filter { if case .waiting = $0.state { return true }; if case .running = $0.state { return true }; return false }.count }
    var overallProgress: Double? {
        guard let job = jobs.first(where: { if case .running = $0.state { return true }; return false }), case .running(let p) = job.state else { return nil }
        return p
    }

    func add(name: String, destination: URL, work: @escaping (Exporter, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        jobs.append(Job(name: name, destination: destination, work: work))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        runNext()
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[i].state {
        case .waiting: jobs[i].state = .cancelled
        case .running: jobs[i].exporter.cancel()
        default: break
        }
    }

    func clearFinished() {
        jobs.removeAll { if case .waiting = $0.state { return false }; if case .running = $0.state { return false }; return true }
    }

    private func runNext() {
        guard !running, let i = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        running = true
        let job = jobs[i]
        jobs[i].state = .running(0)
        Task {
            do {
                try await job.work(job.exporter) { value in
                    Task { @MainActor in self.update(job.id, .running(value)) }
                }
                update(job.id, .done)
                notify("Export terminé", job.destination.lastPathComponent)
            } catch is CancellationError {
                update(job.id, .cancelled)
            } catch {
                update(job.id, .failed(error.localizedDescription))
                notify("Export échoué", "\(job.name) : \(error.localizedDescription)")
            }
            running = false
            runNext()
        }
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .running = state, case .done = jobs[i].state { return }
        jobs[i].state = state
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
