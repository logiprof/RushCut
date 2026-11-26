import SwiftUI
import AppKit
import AVFoundation

/// Lecteur : aperçu au format du projet, poignées de transformation, commandes de lecture.
struct PlayerPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: PlaybackController
    @ObservedObject var library: MediaLibrary

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let canvas = model.project.settings.canvasSize
                let fitted = Geometry.aspectFit(canvas, in: CGSize(width: geo.size.width - 24, height: geo.size.height - 24))
                ZStack {
                    Color.black.opacity(0.92)
                    ZStack {
                        PlayerLayerView(player: playback.player)
                        TransformOverlay(model: model, playback: playback, canvas: canvas, viewSize: fitted)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipped()
                    if model.project.duration == .zero {
                        VStack(spacing: 8) {
                            Image(systemName: "film.stack").font(.system(size: 36))
                            Text("Importez des médias puis glissez-les dans la timeline")
                        }
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                    }
                }
            }
            Divider()
            TransportBar(model: model, playback: playback)
        }
        .background(Theme.panel)
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text(playback.currentTime.timecode(fps: model.fps))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("/ \(playback.duration.timecode(fps: model.fps))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 8)
            Button { playback.seek(to: .zero) } label: { Image(systemName: "backward.end.fill") }
                .help("Aller au début")
            Button { playback.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Image précédente (←)")
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 30)
            }
            .help("Lecture / pause (Espace)")
            Button { playback.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Image suivante (→)")
            Button { playback.seek(to: playback.duration) } label: { Image(systemName: "forward.end.fill") }
                .help("Aller à la fin")
            Spacer(minLength: 8)
            ViewThatFits {
                Text("\(model.project.settings.formatLabel) · \(model.project.settings.width)×\(model.project.settings.height)")
                Text(model.project.settings.formatLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Couche AVPlayer sans commandes système.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Cadre et poignées du calque sélectionné : glisser pour déplacer, coin pour redimensionner,
/// guides magnétiques au centre. Un clic sur l'image sélectionne le calque du dessus.
struct TransformOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: PlaybackController
    let canvas: CGSize
    let viewSize: CGSize

    private enum DragMode { case move, scale }
    @State private var mode: DragMode?
    @State private var startTransform = Transform()
    @State private var startDistance: CGFloat = 1
    @State private var guideX = false
    @State private var guideY = false

    private var scaleToView: CGFloat { viewSize.width / max(canvas.width, 1) }

    var body: some View {
        let selected = selectedVisibleClip
        ZStack {
            Color.clear.contentShape(Rectangle())
            if let clip = selected, let g = geometry(for: clip) {
                Path { p in
                    let c = g.corners
                    p.move(to: c[0]); p.addLine(to: c[1]); p.addLine(to: c[2]); p.addLine(to: c[3]); p.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(g.corners[i])
                }
            }
            if guideX {
                Path { p in
                    p.move(to: CGPoint(x: viewSize.width / 2, y: 0))
                    p.addLine(to: CGPoint(x: viewSize.width / 2, y: viewSize.height))
                }
                .stroke(Color.yellow.opacity(0.85), lineWidth: 1)
            }
            if guideY {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: viewSize.height / 2))
                    p.addLine(to: CGPoint(x: viewSize.width, y: viewSize.height / 2))
                }
                .stroke(Color.yellow.opacity(0.85), lineWidth: 1)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .gesture(dragGesture)
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            TextFocus.release()
            selectTopClip(at: value.location)
        })
    }

    private var activeVisualClips: [(Clip, Track)] {
        let t = playback.currentTime
        var result: [(Clip, Track)] = []
        for track in model.project.tracks where track.kind.isVisual && !track.isHidden {
            for clip in track.clips where clip.contains(t) { result.append((clip, track)) }
        }
        return result
    }

    private var selectedVisibleClip: Clip? {
        guard let id = model.selection.first, model.selection.count == 1 else { return nil }
        return activeVisualClips.first { $0.0.id == id }?.0
    }

    /// Taille source d'un calque à l'échelle de l'aperçu.
    private func geometry(for clip: Clip) -> LayerGeometry? {
        if let text = clip.text {
            let size = TextRenderer.size(text, canvas: viewSize)
            return Geometry.layer(sourceSize: size, canvas: viewSize, fit: .none, transform: clip.transform)
        }
        guard let media = model.project.media(clip.mediaID), media.hasVideo else { return nil }
        let source = Geometry.croppedSize(media.pixelSize, crop: clip.crop)
        return Geometry.layer(sourceSize: source, canvas: viewSize, fit: clip.fit, transform: clip.transform)
    }

    private func selectTopClip(at point: CGPoint) {
        for (clip, _) in activeVisualClips.reversed() {
            if let g = geometry(for: clip), g.contains(point) {
                model.select(clip.id, extend: false)
                return
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if mode == nil {
                    TextFocus.release()
                    if let clip = selectedVisibleClip, let g = geometry(for: clip) {
                        let nearCorner = g.corners.contains { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) < 12 }
                        if nearCorner {
                            mode = .scale
                        } else if g.contains(value.startLocation) {
                            mode = .move
                        }
                        startTransform = clip.transform
                        startDistance = max(1, hypot(value.startLocation.x - g.center.x, value.startLocation.y - g.center.y))
                    } else {
                        selectTopClip(at: value.startLocation)
                        if let clip = selectedVisibleClip {
                            mode = .move
                            startTransform = clip.transform
                        }
                    }
                }
                guard let mode, let clip = selectedVisibleClip else { return }
                var t = startTransform
                switch mode {
                case .move:
                    t.positionX = startTransform.positionX + Double(value.translation.width / max(viewSize.width, 1))
                    t.positionY = startTransform.positionY + Double(value.translation.height / max(viewSize.height, 1))
                    // Guides magnétiques au centre (6 points).
                    let snapX = 6 / max(viewSize.width, 1), snapY = 6 / max(viewSize.height, 1)
                    guideX = abs(t.positionX) < Double(snapX)
                    guideY = abs(t.positionY) < Double(snapY)
                    if guideX { t.positionX = 0 }
                    if guideY { t.positionY = 0 }
                    model.updateClip(clip.id, "Déplacer dans l'image", coalesce: "position") { $0.transform = t }
                case .scale:
                    guard let g = geometry(for: clip) else { return }
                    let d = hypot(value.location.x - g.center.x, value.location.y - g.center.y)
                    t.scale = max(0.05, min(10, startTransform.scale * Double(d / startDistance)))
                    model.updateClip(clip.id, "Redimensionner", coalesce: "echelle") { $0.transform.scale = t.scale }
                }
            }
            .onEnded { _ in
                mode = nil
                guideX = false
                guideY = false
            }
    }
}
