import Foundation

/// Une ligne de sous-titre, avec le minutage de chaque mot quand il est connu.
struct SubtitleCue: Equatable, Sendable {
    var start: RTime
    var end: RTime
    var text: String
    var words: [WordTiming] = []
}

enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt, vtt
    var id: String { rawValue }
    var label: String { self == .srt ? "SubRip (.srt)" : "WebVTT (.vtt)" }
}

enum Subtitles {
    // MARK: Regroupement des mots

    /// Regroupe des mots minutés en lignes lisibles : au plus `maxChars` caractères et `maxSeconds` secondes,
    /// coupure aux fins de phrase et aux silences.
    static func group(_ words: [WordTiming], maxChars: Int = 42, maxSeconds: Double = 3.5, pause: Double = 0.6) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
            cues.append(SubtitleCue(start: first.start, end: last.end, text: text, words: current))
            current = []
        }

        for word in words {
            let w = WordTiming(text: word.text.trimmingCharacters(in: .whitespacesAndNewlines), start: word.start, end: word.end)
            guard !w.text.isEmpty else { continue }
            if let last = current.last, let first = current.first {
                let length = current.map(\.text.count).reduce(0, +) + current.count + w.text.count
                let gap = (w.start - last.end).seconds
                let span = (w.end - first.start).seconds
                let sentenceEnd = [".", "!", "?", "…"].contains { last.text.hasSuffix($0) }
                if length > maxChars || span > maxSeconds || gap > pause || sentenceEnd { flush() }
            }
            current.append(w)
        }
        flush()
        // Laisse chaque ligne affichée jusqu'à la suivante (sans dépasser 0,8 s de silence).
        for i in cues.indices.dropLast() {
            let next = cues[i + 1].start
            let extended = min(next, cues[i].end + RTime(seconds: 0.8))
            if extended > cues[i].end { cues[i].end = extended }
        }
        return cues
    }

    // MARK: SRT / VTT

    static func timestamp(_ t: RTime, format: SubtitleFormat) -> String {
        let ms = max(0, Int((t.seconds * 1000).rounded()))
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        let sep = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, f)
    }

    static func format(_ cues: [SubtitleCue], as format: SubtitleFormat) -> String {
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        for (i, cue) in cues.enumerated() {
            if format == .srt { out += "\(i + 1)\n" }
            out += "\(timestamp(cue.start, format: format)) --> \(timestamp(cue.end, format: format))\n"
            out += cue.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return out
    }

    /// Lit un horodatage SRT (00:00:01,500) ou VTT (00:01.500 ou 00:00:01.500).
    static func parseTime(_ s: String) -> RTime? {
        let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        guard let last = Double(parts[parts.count - 1]) else { return nil }
        var seconds = 0.0
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
            seconds = h * 3600 + m * 60
        } else {
            guard let m = Double(parts[0]) else { return nil }
            seconds = m * 60
        }
        return RTime(seconds: seconds + last)
    }

    /// Lit un fichier .srt ou .vtt (les balises de style sont retirées).
    static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[timeIndex].components(separatedBy: "-->")
            guard sides.count == 2,
                  let start = parseTime(sides[0]),
                  let end = parseTime(sides[1].split(separator: " ").first.map(String.init) ?? sides[1]) else { continue }
            let text = lines[(timeIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }
}

extension Project {
    /// Sous-titres du projet (clips de texte marqués comme sous-titres), dans l'ordre.
    var subtitleClips: [Clip] {
        tracks.filter { $0.kind == .text }.flatMap(\.clips).filter { $0.text?.isSubtitle == true }.sorted { $0.start < $1.start }
    }

    var subtitleCues: [SubtitleCue] {
        subtitleClips.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text?.string ?? "") }
    }

    /// Style par défaut des sous-titres : blanc gras, contour noir, en bas du cadre.
    static func defaultSubtitleStyle(portrait: Bool) -> TextContent {
        var t = TextContent()
        t.fontSize = portrait ? 0.045 : 0.055
        t.strokeEnabled = true
        t.strokeWidth = 0.14
        t.shadowEnabled = true
        t.shadowBlur = 0.1
        t.isSubtitle = true
        return t
    }

    /// Remplace (ou ajoute) les sous-titres. Les lignes vont sur une piste de texte dédiée.
    @discardableResult
    mutating func setSubtitles(_ cues: [SubtitleCue], style: TextContent? = nil, replace: Bool = true) -> [UUID] {
        let portrait = settings.height > settings.width
        var base = style ?? subtitleClips.first?.text ?? Project.defaultSubtitleStyle(portrait: portrait)
        base.isSubtitle = true
        if replace {
            for ti in tracks.indices where tracks[ti].kind == .text {
                tracks[ti].clips.removeAll { $0.text?.isSubtitle == true }
            }
            tracks.removeAll { $0.kind == .text && $0.clips.isEmpty }
        }
        var track = Track(kind: .text)
        var ids: [UUID] = []
        let fps = settings.frameRate
        for cue in cues {
            var clip = Clip()
            var t = base
            t.string = cue.text
            t.words = cue.words.map { WordTiming(text: $0.text, start: $0.start - cue.start, end: $0.end - cue.start) }
            clip.text = t
            clip.name = String(cue.text.prefix(30))
            clip.fit = .none
            clip.start = cue.start.snapped(fps: fps)
            clip.duration = max(RTime.frame(fps: fps), (cue.end - cue.start).snapped(fps: fps))
            clip.transform.positionY = portrait ? 0.28 : 0.38
            if let last = track.clips.last, clip.start < last.end {
                track.clips[track.clips.count - 1].duration = max(RTime.frame(fps: fps), clip.start - last.start)
            }
            track.clips.append(clip)
            ids.append(clip.id)
        }
        guard !track.clips.isEmpty else { return [] }
        tracks.append(track)
        return ids
    }
}
