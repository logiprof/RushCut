import Foundation
import AVFoundation
import ScreenCaptureKit

/// Enregistrement de l'écran (ScreenCaptureKit), avec le son du Mac et le micro si demandé.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCRecordingOutputDelegate {
    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    @Published private(set) var displays: [Display] = []
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var content: SCShareableContent?
    private var timer: Timer?
    private var finished: CheckedContinuation<Void, Never>?
    private(set) var fileURL: URL?

    func loadDisplays() async {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = c
            displays = c.displays.enumerated().map { i, d in Display(id: d.displayID, name: "Écran \(i + 1) (\(d.width)×\(d.height))") }
        } catch {
            errorMessage = "RushCut n'a pas accès à l'écran. Autorisez-le dans Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et de l'audio système, puis relancez RushCut."
        }
    }

    func start(displayID: CGDirectDisplayID, systemAudio: Bool, microphone: Bool, folder: URL) async {
        guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = systemAudio
        config.captureMicrophone = microphone
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("Écran \(stamp).mov")
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mov
        recordingConfig.videoCodecType = .hevc
        do {
            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            let o = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            try s.addRecordingOutput(o)
            try await s.startCapture()
            stream = s
            output = o
            fileURL = url
            isRecording = true
            elapsed = 0
            let begin = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed = Date().timeIntervalSince(begin) }
            }
        } catch {
            errorMessage = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    /// Arrête et attend que le fichier soit complet.
    func stop() async -> URL? {
        timer?.invalidate()
        timer = nil
        guard let stream, isRecording else { return nil }
        isRecording = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            Task {
                try? await stream.stopCapture()
                // Sécurité : si la fin n'est pas signalée, on continue après 3 s.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.resumeFinished()
            }
        }
        self.stream = nil
        output = nil
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    private func resumeFinished() {
        finished?.resume()
        finished = nil
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = "L'enregistrement s'est arrêté : \(error.localizedDescription)"
            self.resumeFinished()
        }
    }
}
