import SwiftUI
import AppKit

/// Un clip dans la timeline : miniatures ou forme d'onde, poignées de rognage et de fondu,
/// glisser pour déplacer (entre pistes aussi), avec aimantation.
struct ClipView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var library: MediaLibrary
    let clip: Clip
    let row: TrackRowLayout
    let rows: [TrackRowLayout]

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var trimStartDelta: CGFloat = 0
    @State private var trimEndDelta: CGFloat = 0
    @State private var fadeDrag: (edge: TrimEdge, value: RTime)?

    private var pps: Double { model.pixelsPerSecond }
    private var media: MediaRef? { model.project.media(clip.mediaID) }
    private var isSelected: Bool { model.selection.contains(clip.id) }
    private var isAudioRow: Bool { row.track.kind == .audio }
    private var isMissing: Bool { clip.mediaID.map { library.missing.contains($0) } ?? false }
    private let handleWidth: CGFloat = 8

    var body: some View {
        let baseX = CGFloat(clip.start.seconds * pps)
        let baseWidth = CGFloat(clip.duration.seconds * pps)
        let x = baseX + trimStartDelta + (isDragging ? dragOffset.width : 0)
        let width = max(3, baseWidth - trimStartDelta + trimEndDelta)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(baseColor.opacity(row.track.isHidden ? 0.35 : 0.9))
            content(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            fadeOverlay(width: width)
            markers(width: width)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(4)
                .frame(maxWidth: max(0, width - 8), alignment: .leading)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white : (isMissing ? Theme.missing : Color.black.opacity(0.4)), lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
            if isSelected && !row.track.isLocked {
                trimHandles(width: width)
                if hasAudio { fadeHandles(width: width) }
            }
        }
        .frame(width: width, height: row.height)
        .contentShape(Rectangle())
        .offset(x: x, y: row.y + (isDragging ? dragOffset.height : 0))
        .zIndex(isDragging ? 10 : (isSelected ? 1 : 0))
        .opacity(isDragging ? 0.85 : 1)
        .onTapGesture {
            TextFocus.release()
            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            model.select(clip.id, extend: extend)
        }
        .gesture(moveGesture)
        .contextMenu { contextMenu }
        .help(helpText)
    }

    // MARK: - Repères (transition, images clés, vitesse, effets)

    @ViewBuilder
    private func markers(width: CGFloat) -> some View {
        let times = Set(clip.keyframes.values.flatMap { $0.map { $0.time.ticks } }).sorted()
        ZStack(alignment: .topLeading) {
            ForEach(times, id: \.self) { ticks in
                Image(systemName: "diamond.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Color.white)
                    .shadow(radius: 1)
                    .offset(x: CGFloat(RTime(ticks: ticks).seconds * pps) - 3.5, y: row.height - 10)
            }
            HStack(spacing: 3) {
                if clip.speed.rate != 1 {
                    Text(String(format: "×%.2g", clip.speed.rate))
                }
                if !clip.effects.isEmpty && !clip.isEffectOnly { Image(systemName: "sparkles") }
                if clip.filter != nil && !clip.isEffectOnly { Image(systemName: "camera.filters") }
                if clip.mask != nil { Image(systemName: "circle.lefthalf.filled") }
                if clip.animIn != nil || clip.animOut != nil || clip.animLoop != nil { Image(systemName: "wand.and.rays") }
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .frame(width: max(0, width - 4), alignment: .trailing)
            .offset(y: 3)
            .opacity(width > 60 ? 1 : 0)
            if let tr = clip.transitionIn {
                let w = max(10, CGFloat(tr.duration.seconds * pps))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.22))
                    .overlay(Image(systemName: "square.split.2x1.fill").font(.system(size: 9)).foregroundStyle(.white))
                    .frame(width: min(w, width), height: min(18, row.height - 6))
                    .offset(y: (row.height - min(18, row.height - 6)) / 2)
                    .help("Transition « \(TransitionCatalog.byID[tr.type]?.name ?? tr.type) »")
            }
        }
        .frame(width: width, height: row.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Contenu

    private var baseColor: Color {
        if isMissing { return Theme.missing }
        if clip.isText { return Theme.text }
        if clip.isSticker { return Theme.sticker }
        if clip.isEffectOnly { return clip.effects.isEmpty ? Theme.filter : Theme.effect }
        if isAudioRow { return Theme.audio }
        switch media?.kind {
        case .image: return Theme.image
        case .audio: return Theme.audio
        default: return Theme.video
        }
    }

    private var label: String {
        if let text = clip.text { return text.string.replacingOccurrences(of: "\n", with: " ") }
        return clip.name
    }

    private var hasAudio: Bool {
        guard let media else { return false }
        if isAudioRow { return true }
        return media.kind == .video && media.hasAudio && !clip.audio.isMuted
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if clip.isText || clip.isSticker || clip.isEffectOnly {
            HStack {
                Spacer()
                Image(systemName: clip.isText ? "textformat" : (clip.isSticker ? "face.smiling" : (clip.effects.isEmpty ? "camera.filters" : "sparkles")))
                    .foregroundStyle(.white.opacity(0.7)).padding(.trailing, 6)
            }
            .frame(maxHeight: .infinity)
        } else if isAudioRow || media?.kind == .audio {
            WaveformShape(peaks: library.waveforms[clip.mediaID ?? UUID()] ?? [], sourceIn: clip.sourceIn,
                          pixelsPerSecond: pps / max(0.01, clip.speed.rate), gain: clip.audio.linearGain)
                .fill(Color.white.opacity(0.55))
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                ThumbnailStrip(strip: library.strips[clip.mediaID ?? UUID()], sourceIn: clip.sourceIn, pixelsPerSecond: pps / max(0.01, clip.speed.rate))
                if hasAudio && row.height >= 56 {
                    WaveformShape(peaks: library.waveforms[clip.mediaID ?? UUID()] ?? [], sourceIn: clip.sourceIn,
                                  pixelsPerSecond: pps / max(0.01, clip.speed.rate), gain: clip.audio.linearGain)
                        .fill(Color.white.opacity(0.5))
                        .frame(height: 16)
                        .background(Color.black.opacity(0.25))
                }
            }
        }
    }

    @ViewBuilder
    private func fadeOverlay(width: CGFloat) -> some View {
        if hasAudio {
            let fadeIn = CGFloat((fadeDrag?.edge == .start ? fadeDrag!.value : clip.audio.fadeIn).seconds * pps)
            let fadeOut = CGFloat((fadeDrag?.edge == .end ? fadeDrag!.value : clip.audio.fadeOut).seconds * pps)
            Path { p in
                if fadeIn > 0 {
                    p.move(to: CGPoint(x: 0, y: row.height))
                    p.addLine(to: CGPoint(x: fadeIn, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: 0))
                    p.closeSubpath()
                }
                if fadeOut > 0 {
                    p.move(to: CGPoint(x: width, y: row.height))
                    p.addLine(to: CGPoint(x: width - fadeOut, y: 0))
                    p.addLine(to: CGPoint(x: width, y: 0))
                    p.closeSubpath()
                }
            }
            .fill(Color.black.opacity(0.35))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Poignées

    private func trimHandles(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            handle
                .gesture(trimGesture(edge: .start))
            handle
                .offset(x: width - handleWidth)
                .gesture(trimGesture(edge: .end))
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: handleWidth, height: row.height)
            .overlay(Rectangle().fill(Color.black.opacity(0.4)).frame(width: 2, height: row.height * 0.4))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func fadeHandles(width: CGFloat) -> some View {
        let fadeIn = CGFloat(clip.audio.fadeIn.seconds * pps)
        let fadeOut = CGFloat(clip.audio.fadeOut.seconds * pps)
        return ZStack(alignment: .topLeading) {
            Circle().fill(Color.white).frame(width: 10, height: 10)
                .offset(x: min(max(handleWidth, fadeIn) , width / 2) - 5, y: 2)
                .gesture(fadeGesture(edge: .start))
                .help("Fondu d'ouverture : glissez vers la droite")
            Circle().fill(Color.white).frame(width: 10, height: 10)
                .offset(x: max(width / 2, width - max(handleWidth, fadeOut)) - 5, y: 2)
                .gesture(fadeGesture(edge: .end))
                .help("Fondu de fermeture : glissez vers la gauche")
        }
    }

    // MARK: - Gestes

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("pistes"))
            .onChanged { value in
                guard !row.track.isLocked else { return }
                if !isDragging {
                    isDragging = true
                    TextFocus.release()
                    if !isSelected { model.select(clip.id, extend: false) }
                }
                var dx = value.translation.width
                if model.snapping {
                    dx = snappedDelta(dx)
                }
                dragOffset = CGSize(width: dx, height: value.translation.height)
            }
            .onEnded { value in
                guard isDragging else { return }
                let dx = model.snapping ? snappedDelta(value.translation.width) : value.translation.width
                let newStart = clip.start + RTime(seconds: Double(dx) / pps)
                let y = row.y + row.height / 2 + value.translation.height
                var target = TimelineMetrics.target(at: y, rows: rows)
                if abs(value.translation.height) < row.height / 2 { target = .existing(row.index) }
                isDragging = false
                dragOffset = .zero
                model.move(clip.id, to: max(.zero, newStart), target: target)
            }
    }

    /// Aimantation : le début ou la fin du clip colle au point le plus proche (8 points).
    private func snappedDelta(_ dx: CGFloat) -> CGFloat {
        let points = model.project.snapPoints(excluding: [clip.id], playhead: model.playback.currentTime)
        let startX = CGFloat(clip.start.seconds * pps) + dx
        let endX = startX + CGFloat(clip.duration.seconds * pps)
        var best: CGFloat?
        for p in points {
            let px = CGFloat(p.seconds * pps)
            for edge in [startX, endX] {
                let d = px - edge
                if abs(d) < 8, abs(d) < abs(best ?? .infinity) { best = d }
            }
        }
        return dx + (best ?? 0)
    }

    private func snapX(_ x: CGFloat) -> CGFloat {
        guard model.snapping else { return x }
        let points = model.project.snapPoints(excluding: [clip.id], playhead: model.playback.currentTime)
        for p in points {
            let px = CGFloat(p.seconds * pps)
            if abs(px - x) < 8 { return px }
        }
        return x
    }

    private func trimGesture(edge: TrimEdge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("pistes"))
            .onChanged { value in
                switch edge {
                case .start:
                    let x = snapX(CGFloat(clip.start.seconds * pps) + value.translation.width)
                    trimStartDelta = min(x - CGFloat(clip.start.seconds * pps), CGFloat(clip.duration.seconds * pps) - 3)
                case .end:
                    let x = snapX(CGFloat(clip.end.seconds * pps) + value.translation.width)
                    trimEndDelta = max(x - CGFloat(clip.end.seconds * pps), -CGFloat(clip.duration.seconds * pps) + 3)
                }
            }
            .onEnded { _ in
                let time: RTime
                switch edge {
                case .start: time = clip.start + RTime(seconds: Double(trimStartDelta) / pps)
                case .end: time = clip.end + RTime(seconds: Double(trimEndDelta) / pps)
                }
                trimStartDelta = 0
                trimEndDelta = 0
                model.trim(clip.id, edge: edge, to: time)
            }
    }

    private func fadeGesture(edge: TrimEdge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("pistes"))
            .onChanged { value in
                let base = edge == .start ? clip.audio.fadeIn : clip.audio.fadeOut
                let delta = RTime(seconds: Double(edge == .start ? value.translation.width : -value.translation.width) / pps)
                let limit = RTime(ticks: clip.duration.ticks / 2)
                fadeDrag = (edge, min(max(.zero, base + delta), limit).snapped(fps: model.fps))
            }
            .onEnded { _ in
                guard let drag = fadeDrag else { return }
                fadeDrag = nil
                model.updateClip(clip.id, drag.edge == .start ? "Fondu d'ouverture" : "Fondu de fermeture") { c in
                    if drag.edge == .start { c.audio.fadeIn = drag.value } else { c.audio.fadeOut = drag.value }
                }
            }
    }

    // MARK: - Menu

    @ViewBuilder
    private var contextMenu: some View {
        Button("Couper à la tête de lecture") {
            model.select(clip.id, extend: false)
            model.splitAtPlayhead()
        }
        Button("Dupliquer") {
            model.select(clip.id, extend: false)
            model.duplicateSelection()
        }
        Button("Copier") {
            model.select(clip.id, extend: false)
            model.copySelection()
        }
        if hasAudio && !isAudioRow {
            Button("Détacher l'audio") {
                model.select(clip.id, extend: false)
                model.detachAudio()
            }
        }
        if isMissing, let id = clip.mediaID {
            Button("Relier le média…") { model.relink(id) }
        }
        Divider()
        Button("Supprimer", role: .destructive) {
            model.select(clip.id, extend: false)
            model.deleteSelection()
        }
    }

    private var helpText: String {
        var parts = ["\(label) — \(clip.duration.shortLabel)"]
        if isMissing { parts.append("Fichier introuvable : clic droit > Relier le média…") }
        parts.append("Glisser : déplacer · Bords : rogner · Clic droit : actions")
        return parts.joined(separator: "\n")
    }
}

/// Miniatures répétées le long du clip, prises au bon moment de la source.
struct ThumbnailStrip: View {
    let strip: (images: [CGImage], interval: Double)?
    let sourceIn: RTime
    let pixelsPerSecond: Double

    var body: some View {
        Canvas { context, size in
            guard let strip, !strip.images.isEmpty else { return }
            let tileWidth = max(20, size.height * 16 / 9)
            var x: CGFloat = 0
            while x < size.width {
                let t = sourceIn.seconds + Double(x) / pixelsPerSecond
                let index = min(strip.images.count - 1, max(0, Int(t / max(strip.interval, 0.001))))
                let image = Image(decorative: strip.images[index], scale: 1)
                let rect = CGRect(x: x, y: 0, width: tileWidth, height: size.height)
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    let img = strip.images[index]
                    let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
                    let w = size.height * aspect
                    layer.draw(image, in: CGRect(x: x + (tileWidth - w) / 2, y: 0, width: w, height: size.height))
                }
                x += tileWidth
            }
        }
        .opacity(0.9)
    }
}

/// Forme d'onde : barres symétriques à partir des niveaux maximaux.
struct WaveformShape: Shape {
    let peaks: [Float]
    let sourceIn: RTime
    let pixelsPerSecond: Double
    var gain: Float = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty, rect.width > 0 else { return path }
        let perSecond = Double(MediaPreviews.peaksPerSecond)
        let mid = rect.midY
        let step: CGFloat = 2
        var x: CGFloat = 0
        let g = CGFloat(max(0.15, min(1, gain)))
        while x < rect.width {
            let t0 = sourceIn.seconds + Double(x) / pixelsPerSecond
            let t1 = sourceIn.seconds + Double(x + step) / pixelsPerSecond
            let i0 = max(0, Int(t0 * perSecond))
            let i1 = min(peaks.count, max(i0 + 1, Int(t1 * perSecond)))
            var peak: Float = 0
            if i0 < peaks.count {
                for i in i0..<i1 { peak = max(peak, peaks[i]) }
            }
            let h = max(0.5, CGFloat(peak) * rect.height / 2 * g)
            path.addRect(CGRect(x: rect.minX + x, y: mid - h, width: step * 0.7, height: h * 2))
            x += step
        }
        return path
    }
}
