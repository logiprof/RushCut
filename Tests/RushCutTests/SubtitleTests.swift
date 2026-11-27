import Foundation
import Testing
@testable import RushCut

@Suite("Sous-titres")
struct SubtitleTests {
    private func w(_ text: String, _ a: Double, _ b: Double) -> WordTiming { WordTiming(text: text, start: RTime(seconds: a), end: RTime(seconds: b)) }

    @Test func groupingSplitsOnSentencesAndPauses() {
        let words = [w("Bonjour", 0, 0.4), w("à", 0.45, 0.5), w("tous.", 0.55, 0.9), w("Aujourd'hui", 1.0, 1.5),
                     w("on", 1.55, 1.7), w("parle", 1.75, 2.0), w("montage", 3.5, 4.0)]
        let cues = Subtitles.group(words)
        #expect(cues.count == 3)
        #expect(cues[0].text == "Bonjour à tous.")
        #expect(cues[1].text == "Aujourd'hui on parle")
        #expect(cues[2].text == "montage")
        #expect(cues[1].end <= cues[2].start, "Pas de chevauchement")
        #expect(cues[0].words.count == 3)
    }

    @Test func groupingRespectsLength() {
        let words = (0..<30).map { w("mot\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.18) }
        let cues = Subtitles.group(words, maxChars: 30)
        #expect(cues.allSatisfy { $0.text.count <= 30 })
        #expect(cues.map { $0.words.count }.reduce(0, +) == 30)
    }

    @Test func srtRoundTrip() {
        let cues = [SubtitleCue(start: RTime(seconds: 1.5), end: RTime(seconds: 3.25), text: "Première ligne"),
                    SubtitleCue(start: RTime(seconds: 3661.004), end: RTime(seconds: 3662), text: "Deuxième\nsur deux lignes")]
        let srt = Subtitles.format(cues, as: .srt)
        #expect(srt.contains("00:00:01,500 --> 00:00:03,250"))
        #expect(srt.contains("01:01:01,004"))
        let parsed = Subtitles.parse(srt)
        #expect(parsed.count == 2)
        #expect(parsed[1].text == "Deuxième\nsur deux lignes")
        #expect(abs(parsed[0].start.seconds - 1.5) < 0.002)
        let vtt = Subtitles.format(cues, as: .vtt)
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(Subtitles.parse(vtt).count == 2)
    }

    @Test func parsesShortVttAndStripsTags() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.500 align:start\n<b>Salut</b> <i>toi</i>\n\n00:03.000 --> 00:04.000\n{\\an8}Haut\n"
        let cues = Subtitles.parse(vtt)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Salut toi")
        #expect(cues[1].text == "Haut")
        #expect(abs(cues[0].end.seconds - 2.5) < 0.002)
    }

    @Test func projectSubtitlesReplaceAndExport() {
        var p = Project()
        p.settings.frameRate = 30
        let cues = [SubtitleCue(start: .zero, end: RTime(seconds: 2), text: "Un", words: [w("Un", 0.2, 0.6)]),
                    SubtitleCue(start: RTime(seconds: 2), end: RTime(seconds: 4), text: "Deux")]
        p.setSubtitles(cues)
        p.normalize(magnetic: true)
        #expect(p.subtitleClips.count == 2)
        #expect(p.subtitleClips[0].text?.words.first?.start == RTime(seconds: 0.2), "Minutage relatif au clip")
        p.setSubtitles([SubtitleCue(start: .zero, end: RTime(seconds: 1), text: "Seul")])
        p.normalize(magnetic: true)
        #expect(p.subtitleClips.map { $0.text?.string } == ["Seul"])
        #expect(p.subtitleCues.first?.text == "Seul")
    }

    @Test func speechSynthesisWritesFile() async throws {
        let url = TestMedia.tempDirectory().appendingPathComponent("voix.caf")
        do {
            try await SpeechSynth.render("Bonjour", voiceID: nil, to: url)
        } catch {
            // Certaines machines d'intégration n'ont aucune voix installée.
            return
        }
        let media = try await MediaAnalyzer.analyze(url: url)
        #expect(media.kind == .audio)
        #expect(media.duration.seconds > 0.2)
    }
}
