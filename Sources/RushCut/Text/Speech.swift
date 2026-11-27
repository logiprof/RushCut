import Foundation
import AVFoundation
import Speech

/// Reconnaissance vocale sur le Mac (framework Speech de macOS 26), avec le minutage de chaque mot.
enum Transcriber {
    enum Failure: LocalizedError {
        case unsupported(String)
        case noAudio
        case nothingRecognized

        var errorDescription: String? {
            switch self {
            case .unsupported(let lang): return "La langue « \(lang) » n'est pas prise en charge par la reconnaissance vocale de macOS."
            case .noAudio: return "Le projet ne contient aucun son à transcrire."
            case .nothingRecognized: return "Aucune parole n'a été reconnue. Vérifiez la langue choisie et le volume des voix."
            }
        }
    }

    struct Language: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let languages: [Language] = [
        Language(id: "fr-FR", name: "Français"), Language(id: "fr-CH", name: "Français (Suisse)"),
        Language(id: "en-US", name: "Anglais"), Language(id: "de-DE", name: "Allemand"),
        Language(id: "de-CH", name: "Allemand (Suisse)"), Language(id: "it-IT", name: "Italien"),
        Language(id: "es-ES", name: "Espagnol"), Language(id: "pt-PT", name: "Portugais"),
    ]

    /// Transcrit un fichier audio ; `status` reçoit des messages d'avancement en français.
    static func transcribe(file: URL, language: String, status: @escaping @Sendable (String) -> Void) async throws -> [WordTiming] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw Failure.unsupported(language)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Téléchargement du modèle de langue (une seule fois)…")
            try await request.downloadAndInstall()
        }
        status("Reconnaissance de la parole…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)
        async let words = collect(transcriber)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let result = try await words
        guard !result.isEmpty else { throw Failure.nothingRecognized }
        return result
    }

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> [WordTiming] {
        var words: [WordTiming] = []
        for try await result in transcriber.results {
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let text = String(result.text[run.range].characters)
                let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard !tokens.isEmpty else { continue }
                // Un morceau peut contenir plusieurs mots : on partage sa durée selon leur longueur.
                let start = range.start.seconds, duration = range.duration.seconds
                let total = Double(tokens.map(\.count).reduce(0, +))
                var t = start
                for token in tokens {
                    let d = duration * Double(token.count) / max(1, total)
                    words.append(WordTiming(text: token, start: RTime(seconds: t), end: RTime(seconds: t + d)))
                    t += d
                }
            }
        }
        // Colle la ponctuation isolée au mot précédent.
        var merged: [WordTiming] = []
        for w in words {
            if let last = merged.last, w.text.allSatisfy({ ",.;:!?…".contains($0) }) {
                merged[merged.count - 1] = WordTiming(text: last.text + w.text, start: last.start, end: w.end)
            } else {
                merged.append(w)
            }
        }
        return merged
    }

    /// Mélange tout le son du projet dans un fichier temporaire (.m4a), minuté comme la timeline.
    static func renderProjectAudio(_ project: Project) async throws -> URL {
        let built = try await CompositionBuilder.build(project: project, renderSize: CGSize(width: 320, height: 180))
        guard built.hasAudio else { throw Failure.noAudio }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rushcut-son-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: built.asset, presetName: AVAssetExportPresetAppleM4A) else { throw Failure.noAudio }
        session.audioMix = built.audioMix
        session.timeRange = CMTimeRange(start: .zero, duration: built.contentDuration.cmTime)
        try await session.export(to: output, as: .m4a)
        return output
    }
}

/// Voix de synthèse (texte → parole) intégrées à macOS.
enum SpeechSynth {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
        let quality: String
    }

    static func voices(languagePrefix: String? = nil) -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { v in languagePrefix.map { v.language.hasPrefix($0) } ?? true }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { v in
                let quality: String
                switch v.quality {
                case .premium: quality = "premium"
                case .enhanced: quality = "améliorée"
                default: quality = "standard"
                }
                return Voice(id: v.identifier, name: v.name, language: v.language, quality: quality)
            }
            .sorted { ($0.quality == "standard" ? 1 : 0, $0.name) < ($1.quality == "standard" ? 1 : 0, $1.name) }
    }

    private final class Job: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        let synthesizer = AVSpeechSynthesizer()
        var file: AVAudioFile?
        var continuation: CheckedContinuation<Void, Error>?
        let lock = NSLock()

        func finish(_ error: Error? = nil) {
            lock.lock()
            let c = continuation
            continuation = nil
            file = nil
            lock.unlock()
            if let error { c?.resume(throwing: error) } else { c?.resume() }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.finish() }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }
    }

    /// Écrit la phrase lue dans un fichier audio (.caf).
    static func render(_ text: String, voiceID: String?, rate: Float = AVSpeechUtteranceDefaultSpeechRate, pitch: Float = 1, to url: URL) async throws {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = voice }
        else { utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR") }
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        let job = Job()
        job.synthesizer.delegate = job
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            job.continuation = continuation
            job.synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { job.finish(); return }
                job.lock.lock()
                defer { job.lock.unlock() }
                guard job.continuation != nil else { return }
                do {
                    if job.file == nil {
                        job.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                                   commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try job.file?.write(from: pcm)
                } catch {
                    DispatchQueue.global().async { job.finish(error) }
                }
            }
        }
        withExtendedLifetime(job) {}
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RushError.render("la voix de synthèse n'a produit aucun son.")
        }
    }
}
