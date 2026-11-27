import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum LibraryTab: String, CaseIterable, Identifiable {
    case media, audio, text, captions, stickers, effects, transitions, filters
    var id: String { rawValue }
    var label: String {
        switch self {
        case .media: return "Médias"
        case .audio: return "Audio"
        case .text: return "Texte"
        case .captions: return "Sous-titres"
        case .stickers: return "Autocollants"
        case .effects: return "Effets"
        case .transitions: return "Transitions"
        case .filters: return "Filtres"
        }
    }
    var icon: String {
        switch self {
        case .media: return "photo.on.rectangle"
        case .audio: return "music.note"
        case .text: return "textformat"
        case .captions: return "captions.bubble"
        case .stickers: return "face.smiling"
        case .effects: return "sparkles"
        case .transitions: return "square.split.2x1"
        case .filters: return "camera.filters"
        }
    }
}

/// Projet ouvert : toutes les modifications passent par `apply`, qui les rend annulables,
/// remet le projet en ordre, reconstruit l'aperçu et programme la sauvegarde.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var project: Project
    let url: URL

    @Published var selection: Set<UUID> = []
    @Published var pixelsPerSecond: Double = 60
    @Published var snapping = true
    @Published var magneticMain = true
    @Published private(set) var isDirty = false
    @Published private(set) var lastSaved: Date?
    @Published var previewOnly = false
    @Published var exportPresented = false
    @Published var libraryTab: LibraryTab = .media
    @Published var importInProgress = false
    @Published var inspectorTab: InspectorTab = .base
    var attributeClipboard: Clip?
    @Published var subtitleStatus: String?
    @Published var subtitleBusy = false
    private var audioTask: Task<Void, Never>?
    @Published var timelineVisibleWidth: CGFloat = 800

    let playback = PlaybackController()
    let library = MediaLibrary()

    private var undoStack = UndoStack()
    private var clipboard: [Project.ClipboardItem] = []
    private var autosaveTimer: Timer?
    private var rebuildTask: Task<Void, Never>?

    init(project: Project, url: URL) {
        self.project = project
        self.url = url
        playback.fps = project.settings.frameRate
        library.sync(with: project.media)
        rebuild(immediately: true)
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        if project.duration > .zero {
            pixelsPerSecond = max(8, min(200, 900 / max(project.duration.seconds, 5)))
        }
    }

    func teardown() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        rebuildTask?.cancel()
        library.cancelAll()
        playback.teardown()
    }

    var fps: Int { project.settings.frameRate }

    // MARK: - Commandes

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }
    var undoName: String? { undoStack.undoName }
    var redoName: String? { undoStack.redoName }

    /// Applique une modification annulable.
    func apply(_ name: String, coalesce: String? = nil, _ body: (inout Project) -> Void) {
        var next = project
        body(&next)
        next.normalize(magnetic: magneticMain)
        guard next != project else { return }
        undoStack.record(before: project, name: name, coalesceKey: coalesce)
        commit(next)
    }

    private func commit(_ next: Project) {
        let settingsChanged = next.settings != project.settings
        let compositionChanged = next.tracks != project.tracks || next.media != project.media || settingsChanged
        project = next
        isDirty = true
        selection = selection.filter { next.clip($0) != nil }
        playback.fps = next.settings.frameRate
        library.sync(with: next.media)
        if compositionChanged { rebuild() }
    }

    func undo() {
        guard let previous = undoStack.undo(current: project) else { return }
        commit(previous)
    }

    func redo() {
        guard let next = undoStack.redo(current: project) else { return }
        commit(next)
    }

    // MARK: - Aperçu

    private var loadedStructure: Int?

    /// Empreinte de ce qui change la composition elle-même (clips, temps, médias, pistes).
    /// Les réglages purement visuels (position, texte, opacité, fond) et le volume n'en font pas partie :
    /// ils sont appliqués sans recharger le lecteur, ce qui garde l'aperçu fluide pendant les réglages.
    private func structureSignature(_ project: Project) -> Int {
        var p = project
        p.name = ""
        p.markers = []
        p.createdAt = .distantPast
        p.modifiedAt = .distantPast
        p.settings.backgroundColor = .black
        p.settings.backgroundMode = .color
        for ti in p.tracks.indices {
            p.tracks[ti].isHidden = false
            p.tracks[ti].isLocked = false
            for ci in p.tracks[ti].clips.indices {
                var c = p.tracks[ti].clips[ci]
                c.name = ""
                c.transform = Transform()
                c.opacity = 1
                c.crop = CropRect()
                c.fit = .fit
                if c.text != nil { c.text = TextContent() }
                c.audio.volumeDB = 0
                c.audio.fadeIn = .zero
                c.audio.fadeOut = .zero
                p.tracks[ti].clips[ci] = c
            }
        }
        return p.hashValue
    }

    /// Prépare en arrière-plan les sons traités (gain > 0 dB, réduction de bruit), puis rafraîchit l'aperçu.
    private func scheduleAudioPreprocessing(_ snapshot: Project) {
        guard !AudioPreprocessor.missing(snapshot).isEmpty else { return }
        audioTask?.cancel()
        audioTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await AudioPreprocessor.prepare(snapshot)
            if Task.isCancelled { return }
            self?.rebuild(immediately: true)
        }
    }

    func rebuild(immediately: Bool = false) {
        rebuildTask?.cancel()
        let snapshot = project
        let signature = structureSignature(snapshot) &+ AudioPreprocessor.signature(snapshot)
        let swapOnly = signature == loadedStructure
        scheduleAudioPreprocessing(snapshot)
        rebuildTask = Task { [weak self] in
            if !immediately && !swapOnly {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            if Task.isCancelled { return }
            do {
                let built = try await CompositionBuilder.build(project: snapshot)
                if Task.isCancelled { return }
                guard let self else { return }
                if swapOnly {
                    self.playback.update(built)
                } else {
                    self.playback.load(built)
                    self.loadedStructure = signature
                }
            } catch {
                Log.error("Aperçu : \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sélection

    var selectedClips: [Clip] { selection.compactMap { project.clip($0) } }

    var singleSelection: Clip? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return project.clip(id)
    }

    func select(_ id: UUID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func selectAll() {
        selection = Set(project.tracks.flatMap(\.clips).map(\.id))
    }

    // MARK: - Montage

    var playhead: RTime { playback.currentTime }

    func splitAtPlayhead() {
        let t = playhead
        apply("Couper") { $0.split(at: t, clipIDs: self.selection) }
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        apply(ids.count > 1 ? "Supprimer les clips" : "Supprimer le clip") { $0.delete(ids) }
        selection.removeAll()
    }

    func trimToPlayhead(keepRight: Bool) {
        let t = playhead
        apply(keepRight ? "Rogner à gauche" : "Rogner à droite") {
            $0.trimToPlayhead(t, keepRight: keepRight, clipIDs: self.selection)
        }
        if keepRight, let first = selectedClips.first {
            playback.seek(to: first.start)
        }
    }

    func detachAudio() {
        var created: UUID?
        let targets = selection.isEmpty ? Set(project.tracks.flatMap(\.clips).filter { $0.contains(playhead) }.map(\.id)) : selection
        apply("Détacher l'audio") { p in
            for id in targets { if let a = p.detachAudio(id) { created = a } }
        }
        if let created { selection = [created] }
    }

    func copySelection() {
        clipboard = project.clipboardItems(for: selection)
    }

    func paste() {
        guard !clipboard.isEmpty else { return }
        var created: [UUID] = []
        let items = clipboard
        let t = playhead
        apply("Coller") { created = $0.paste(items, at: t) }
        selection = Set(created)
    }

    func duplicateSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        var created: [UUID] = []
        apply("Dupliquer") { created = $0.duplicate(ids) }
        selection = Set(created)
    }

    func addMarker() {
        let t = playhead
        apply("Ajouter un marqueur") { $0.addMarker(at: t) }
    }

    func removeMarker(_ id: UUID) {
        apply("Supprimer le marqueur") { $0.markers.removeAll { $0.id == id } }
    }

    func addMediaToTimeline(_ mediaID: UUID) {
        var created: UUID?
        let kind = project.media(mediaID)?.kind
        let t = playhead
        apply("Ajouter à la timeline") { p in
            created = kind == .audio ? p.addMedia(mediaID, at: t) : p.addMedia(mediaID, at: nil)
        }
        if let created { selection = [created] }
    }

    func dropMedia(_ mediaID: UUID, at time: RTime, target: TrackTarget?) {
        var created: UUID?
        apply("Ajouter à la timeline") { p in
            created = p.addMedia(mediaID, at: max(.zero, time), target: target)
        }
        if let created { selection = [created] }
    }

    func addText(_ content: TextContent) {
        var created: UUID?
        let t = playhead
        apply("Ajouter un texte") { created = $0.addText(content, at: t) }
        if let created { selection = [created] }
    }

    func move(_ id: UUID, to start: RTime, target: TrackTarget) {
        apply("Déplacer") { $0.move(id, to: start, target: target) }
    }

    func trim(_ id: UUID, edge: TrimEdge, to time: RTime) {
        apply("Rogner") { $0.trim(id, edge: edge, to: time) }
    }

    func updateClip(_ id: UUID, _ name: String, coalesce: String? = nil, _ body: @escaping (inout Clip) -> Void) {
        apply(name, coalesce: coalesce.map { "\(id)-\($0)" }) { $0.updateClip(id, body) }
    }

    func updateSettings(_ name: String, coalesce: String? = nil, _ body: @escaping (inout ProjectSettings) -> Void) {
        apply(name, coalesce: coalesce) { body(&$0.settings) }
    }

    func renameProject(_ name: String) {
        apply("Renommer le projet", coalesce: "nom") { $0.name = name }
    }

    func toggleTrack(_ index: Int, _ keyPath: WritableKeyPath<Track, Bool>, name: String) {
        apply(name) { p in
            guard p.tracks.indices.contains(index) else { return }
            p.tracks[index][keyPath: keyPath].toggle()
        }
    }

    func removeMedia(_ id: UUID) {
        guard !project.isUsed(mediaID: id) else { return }
        apply("Retirer de la bibliothèque") { $0.media.removeAll { $0.id == id } }
    }

    // MARK: - Import

    func importPanel() {
        let panel = NSOpenPanel()
        panel.title = "Importer des médias"
        panel.prompt = "Importer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importMedia(urls) }
    }

    /// Importe des fichiers (ou dossiers) et renvoie les identifiants des médias ajoutés, dans l'ordre.
    @discardableResult
    func importMedia(_ urls: [URL]) async -> [UUID] {
        let files = MediaAnalyzer.expand(urls).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !files.isEmpty else { return [] }
        importInProgress = true
        defer { importInProgress = false }
        var results: [(Int, MediaRef)] = []
        var failures: [String] = []
        await withTaskGroup(of: (Int, Result<MediaRef, Error>).self) { group in
            for (i, file) in files.enumerated() {
                group.addTask {
                    do { return (i, .success(try await MediaAnalyzer.analyze(url: file))) }
                    catch { return (i, .failure(error)) }
                }
            }
            for await (i, result) in group {
                switch result {
                case .success(let media): results.append((i, media))
                case .failure(let error): failures.append("• \(files[i].lastPathComponent) : \(error.localizedDescription)")
                }
            }
        }
        results.sort { $0.0 < $1.0 }
        var ids: [UUID] = []
        var added: [MediaRef] = []
        for (_, media) in results {
            if let existing = project.media.first(where: { $0.path == media.path }) {
                ids.append(existing.id)
            } else {
                added.append(media)
                ids.append(media.id)
            }
        }
        if !added.isEmpty {
            apply(added.count > 1 ? "Importer \(added.count) médias" : "Importer un média") { $0.media.append(contentsOf: added) }
        }
        if !failures.isEmpty {
            AppModel.shared.alert = AppAlert(title: "Certains fichiers n'ont pas été importés",
                                             message: failures.prefix(12).joined(separator: "\n"))
        }
        Log.info("Import : \(added.count) ajoutés, \(failures.count) refusés")
        return ids
    }

    /// Indique le nouvel emplacement d'un média introuvable.
    func relink(_ mediaID: UUID) {
        guard let media = project.media(mediaID) else { return }
        let panel = NSOpenPanel()
        panel.title = "Relier « \(media.name) »"
        panel.prompt = "Relier"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                var fresh = try await MediaAnalyzer.analyze(url: url)
                fresh.id = mediaID
                apply("Relier le média") { p in
                    if let i = p.media.firstIndex(where: { $0.id == mediaID }) { p.media[i] = fresh }
                }
            } catch {
                AppModel.shared.show(error, title: "Média non relié")
            }
        }
    }

    // MARK: - Sauvegarde

    private func autosave() {
        if isDirty { saveNow() }
    }

    func saveNow() {
        var toSave = project
        toSave.modifiedAt = Date()
        let poster = posterImage()
        do {
            try ProjectStore.save(toSave, to: url, poster: poster)
            isDirty = false
            lastSaved = Date()
        } catch {
            AppModel.shared.show(error, title: "Enregistrement impossible")
        }
    }

    private func posterImage() -> CGImage? {
        for track in project.tracks where track.kind.isVisual {
            for clip in track.clips {
                if let p = library.poster(clip.mediaID) { return p }
            }
        }
        return nil
    }

    // MARK: - Zoom de la timeline

    func zoom(by factor: Double) {
        pixelsPerSecond = min(600, max(2, pixelsPerSecond * factor))
    }

    func zoomToFit() {
        let seconds = max(project.duration.seconds, 5)
        pixelsPerSecond = min(600, max(2, Double(timelineVisibleWidth - 60) / seconds))
    }
}
