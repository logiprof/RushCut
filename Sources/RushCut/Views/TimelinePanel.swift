import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Disposition verticale des pistes : pistes visuelles en haut (la plus haute est dessinée au-dessus),
/// piste principale au milieu, pistes audio en dessous.
struct TrackRowLayout: Identifiable {
    var index: Int
    var y: CGFloat
    var height: CGFloat
    var track: Track
    var id: UUID { track.id }
}

enum TimelineMetrics {
    static let rulerHeight: CGFloat = 28
    static let headerWidth: CGFloat = 168
    static let rowSpacing: CGFloat = 4
    static let topPadding: CGFloat = 8

    static func height(for track: Track) -> CGFloat {
        if track.isMain { return 70 }
        switch track.kind {
        case .audio: return 46
        case .text, .sticker, .effect: return 34
        case .video: return 56
        }
    }

    static func rows(for project: Project) -> [TrackRowLayout] {
        var order: [Int] = []
        let visual = project.tracks.indices.filter { project.tracks[$0].kind.isVisual }
        order.append(contentsOf: visual.reversed())
        order.append(contentsOf: project.tracks.indices.filter { project.tracks[$0].kind == .audio })
        var y = topPadding
        var rows: [TrackRowLayout] = []
        for i in order {
            let h = height(for: project.tracks[i])
            rows.append(TrackRowLayout(index: i, y: y, height: h, track: project.tracks[i]))
            y += h + rowSpacing
        }
        return rows
    }

    static func totalHeight(_ rows: [TrackRowLayout]) -> CGFloat {
        (rows.last.map { $0.y + $0.height } ?? 0) + 60
    }

    /// Piste visée à une hauteur donnée.
    static func target(at y: CGFloat, rows: [TrackRowLayout]) -> TrackTarget {
        if let row = rows.first(where: { y >= $0.y - rowSpacing / 2 && y < $0.y + $0.height + rowSpacing / 2 }) {
            return .existing(row.index)
        }
        return .newTrack
    }

    static func trackName(_ track: Track, in project: Project) -> String {
        if track.isMain { return "Principale" }
        let same = project.tracks.filter { $0.kind == track.kind && !$0.isMain }
        let n = (same.firstIndex { $0.id == track.id } ?? 0) + 1
        switch track.kind {
        case .audio: return "Audio \(n)"
        case .text: return "Texte \(n)"
        case .sticker: return "Autocollants \(n)"
        case .effect: return "Effets \(n)"
        case .video: return "Calque \(n)"
        }
    }
}

struct TimelinePanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var library: MediaLibrary
    @State private var verticalOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var visibleRect: CGRect = .zero
    @State private var dropTargeted = false

    var body: some View {
        let rows = TimelineMetrics.rows(for: model.project)
        let pps = model.pixelsPerSecond
        let contentSeconds = max(model.project.duration.seconds + 30, Double(visibleRect.width) / pps)
        let contentWidth = CGFloat(contentSeconds * pps)
        let totalHeight = TimelineMetrics.totalHeight(rows)

        VStack(spacing: 0) {
            TimelineToolbar(model: model)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: TimelineMetrics.rulerHeight)
                    ZStack(alignment: .topLeading) {
                        ForEach(rows) { row in
                            TrackHeader(model: model, row: row)
                                .frame(width: TimelineMetrics.headerWidth, height: row.height)
                                .offset(y: row.y)
                        }
                    }
                    .frame(width: TimelineMetrics.headerWidth, alignment: .topLeading)
                    .offset(y: -verticalOffset)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                }
                .frame(width: TimelineMetrics.headerWidth)
                .background(Color.black.opacity(0.15))
                Divider()
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        RulerView(model: model, playback: model.playback, width: contentWidth)
                            .frame(width: contentWidth, height: TimelineMetrics.rulerHeight)
                        ScrollView(.vertical) {
                            TracksContent(model: model, library: library, rows: rows, width: contentWidth, height: totalHeight)
                                .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
                        }
                        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                            verticalOffset = y
                        }
                    }
                    .frame(width: contentWidth)
                    .overlay(alignment: .topLeading) {
                        PlayheadLine(playback: model.playback, pixelsPerSecond: pps)
                    }
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, rect in
                    visibleRect = rect
                    model.timelineVisibleWidth = rect.width
                }
                .onReceive(model.playback.$currentTime) { t in
                    followPlayhead(t, pps: pps)
                }
            }
        }
        .background(Theme.panel)
    }

    /// Pendant la lecture, la timeline défile pour garder la tête de lecture visible.
    private func followPlayhead(_ t: RTime, pps: Double) {
        guard model.playback.isPlaying, visibleRect.width > 0 else { return }
        let x = CGFloat(t.seconds * pps)
        if x > visibleRect.maxX - 40 || x < visibleRect.minX {
            scrollPosition.scrollTo(x: max(0, x - 80))
        }
    }
}

struct TimelineToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Group {
                Button { model.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                    .help("Couper à la tête de lecture (⌘B)")
                Button { model.trimToPlayhead(keepRight: true) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Supprimer à gauche de la tête de lecture (Q)")
                Button { model.trimToPlayhead(keepRight: false) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Supprimer à droite de la tête de lecture (W)")
                Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                    .help("Supprimer la sélection (⌫)")
                    .disabled(model.selection.isEmpty)
                Button { model.detachAudio() } label: { Image(systemName: "waveform.badge.minus") }
                    .help("Détacher l'audio (⌥⌘D)")
                Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Dupliquer (⌘D)")
                    .disabled(model.selection.isEmpty)
                Button { model.addMarker() } label: { Image(systemName: "bookmark") }
                    .help("Ajouter un marqueur (M)")
            }
            Divider().frame(height: 18)
            Toggle(isOn: $model.snapping) { Image(systemName: "magnet") }
                .toggleStyle(.button)
                .help("Aimantation (N)")
            Toggle(isOn: $model.magneticMain) { Image(systemName: "rectangle.compress.vertical") }
                .toggleStyle(.button)
                .help("Piste principale magnétique : les clips se suivent sans vide")
            Spacer()
            Button { model.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom arrière (⌘−)")
            Slider(value: Binding(get: { log(model.pixelsPerSecond) }, set: { model.pixelsPerSecond = exp($0) }),
                   in: log(2)...log(600))
                .frame(width: 140)
                .controlSize(.small)
            Button { model.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom avant (⌘+)")
            Button { model.zoomToFit() } label: { Image(systemName: "arrow.left.and.right.square") }
                .help("Ajuster à la fenêtre (⇧Z)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct TrackHeader: View {
    @ObservedObject var model: EditorModel
    let row: TrackRowLayout

    var body: some View {
        let track = row.track
        HStack(spacing: 6) {
            Image(systemName: icon(track))
                .foregroundStyle(color(track))
                .frame(width: 16)
            Text(TimelineMetrics.trackName(track, in: model.project))
                .font(.caption.weight(track.isMain ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if track.kind != .text {
                headerButton(track.isMuted ? "speaker.slash.fill" : "speaker.wave.2", active: track.isMuted,
                             help: track.isMuted ? "Rétablir le son" : "Couper le son de la piste") {
                    model.toggleTrack(row.index, \.isMuted, name: "Son de la piste")
                }
            }
            if track.kind.isVisual {
                headerButton(track.isHidden ? "eye.slash" : "eye", active: track.isHidden,
                             help: track.isHidden ? "Afficher la piste" : "Masquer la piste") {
                    model.toggleTrack(row.index, \.isHidden, name: "Affichage de la piste")
                }
            }
            headerButton(track.isLocked ? "lock.fill" : "lock.open", active: track.isLocked,
                         help: track.isLocked ? "Déverrouiller" : "Verrouiller la piste") {
                model.toggleTrack(row.index, \.isLocked, name: "Verrou de la piste")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(track.isMain ? 0.08 : 0.04)))
        .padding(.horizontal, 4)
    }

    private func headerButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(active ? Color.orange : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func icon(_ track: Track) -> String {
        switch track.kind {
        case .audio: return "music.note"
        case .text: return "textformat"
        default: return track.isMain ? "film.fill" : "square.stack.3d.up"
        }
    }

    private func color(_ track: Track) -> Color {
        switch track.kind {
        case .audio: return Theme.audio
        case .text: return Theme.text
        default: return Theme.video
        }
    }
}

/// Règle temporelle : clic ou glisser pour déplacer la tête de lecture ; marqueurs.
struct RulerView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: PlaybackController
    let width: CGFloat

    var body: some View {
        let pps = model.pixelsPerSecond
        let markers = model.project.markers
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let major = majorInterval(pps: pps)
                let minor = major / 5
                var i = 0
                while CGFloat(Double(i) * minor * pps) <= size.width {
                    let t = Double(i) * minor
                    let x = CGFloat(t * pps)
                    let isMajor = i % 5 == 0
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 12 : 5)))
                    context.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.9 : 0.5)), lineWidth: 1)
                    if isMajor {
                        context.draw(Text(label(t, major: major)).font(.system(size: 9.5).monospacedDigit()).foregroundColor(.secondary),
                                     at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                    }
                    i += 1
                }
            }
            if model.inPoint != nil || model.outPoint != nil {
                let a = CGFloat((model.inPoint ?? .zero).seconds * pps)
                let b = CGFloat((model.outPoint ?? model.project.duration).seconds * pps)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: max(2, b - a), height: TimelineMetrics.rulerHeight)
                    .offset(x: a)
                    .overlay(alignment: .topLeading) {
                        Text("E/S").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentColor).offset(x: a + 3, y: 1)
                    }
                    .allowsHitTesting(false)
                    .help("Plage d'export (I : entrée, O : sortie, X : effacer)")
            }
            ForEach(markers) { marker in
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(cgColor: marker.color.cgColor))
                    .position(x: CGFloat(marker.time.seconds * pps), y: TimelineMetrics.rulerHeight - 9)
                    .help(marker.name)
                    .contextMenu {
                        Button("Aller au marqueur") { playback.seek(to: marker.time) }
                        Button("Supprimer le marqueur", role: .destructive) { model.removeMarker(marker.id) }
                    }
            }
        }
        .frame(width: width, height: TimelineMetrics.rulerHeight)
        .background(Color.black.opacity(0.2))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            TextFocus.release()
            playback.seek(to: RTime(seconds: max(0, Double(value.location.x) / pps)))
        })
        .help("Cliquez ou glissez pour vous déplacer dans la vidéo")
    }

    private func majorInterval(pps: Double) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        return candidates.first { $0 * pps >= 70 } ?? 1800
    }

    /// « 0:05 » pour les graduations d'une seconde ou plus, « 2,5 s » pour les plus fines.
    private func label(_ t: Double, major: Double) -> String {
        let total = Int(t.rounded())
        if major < 1 {
            return String(format: "%.1f s", t).replacingOccurrences(of: ".", with: ",")
        }
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Tête de lecture (observe seulement la lecture pour ne pas redessiner toute la timeline).
struct PlayheadLine: View {
    @ObservedObject var playback: PlaybackController
    let pixelsPerSecond: Double

    var body: some View {
        let x = CGFloat(playback.currentTime.seconds * pixelsPerSecond)
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.playhead).frame(width: 2)
            Path { p in
                p.move(to: CGPoint(x: -6, y: 0))
                p.addLine(to: CGPoint(x: 6, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 9))
                p.closeSubpath()
            }
            .fill(Theme.playhead)
            .frame(width: 0, height: 9)
        }
        .frame(maxHeight: .infinity)
        .offset(x: x - 1)
        .allowsHitTesting(false)
    }
}

/// Zone des pistes : fonds, clips, dépôt depuis la bibliothèque ou le Finder.
struct TracksContent: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var library: MediaLibrary
    let rows: [TrackRowLayout]
    let width: CGFloat
    let height: CGFloat
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    TextFocus.release()
                    model.selection.removeAll()
                }
            ForEach(rows) { row in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(row.track.isMain ? 0.07 : 0.035))
                    .frame(width: width, height: row.height)
                    .offset(y: row.y)
                    .allowsHitTesting(false)
            }
            ForEach(rows) { row in
                ForEach(row.track.clips) { clip in
                    ClipView(model: model, library: library, clip: clip, row: row, rows: rows)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .coordinateSpace(name: "pistes")
        .onDrop(of: [.utf8PlainText, .plainText, .fileURL], isTargeted: $dropTargeted) { providers, location in
            handleDrop(providers, at: location)
        }
        .overlay {
            if dropTargeted {
                Color.accentColor.opacity(0.06).allowsHitTesting(false)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let time = RTime(seconds: max(0, Double(location.x) / model.pixelsPerSecond)).snapped(fps: model.fps)
        let target = TimelineMetrics.target(at: location.y, rows: rows)
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            loadFileURLs(providers) { urls in
                Task {
                    let ids = await model.importMedia(urls)
                    var t = time
                    for id in ids {
                        model.dropMedia(id, at: t, target: target)
                        if let m = model.project.media(id) { t += m.kind == .image ? RTime(seconds: 5) : m.duration }
                    }
                }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = (object as? NSString).map({ String($0) }), string.hasPrefix("rushcut-media:"),
                  let id = UUID(uuidString: String(string.dropFirst("rushcut-media:".count))) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.dropMedia(id, at: time, target: target) }
            }
        }
        return true
    }
}
