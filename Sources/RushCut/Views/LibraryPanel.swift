import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MediaSort: String, CaseIterable, Identifiable {
    case date, name, type
    var id: String { rawValue }
    var label: String {
        switch self {
        case .date: return "Date d'import"
        case .name: return "Nom"
        case .type: return "Type"
        }
    }
}

/// Bibliothèque : médias du projet et modèles de texte.
struct LibraryPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var library: MediaLibrary
    @State private var search = ""
    @State private var sort: MediaSort = .date
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.libraryTab) {
                ForEach(LibraryTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch model.libraryTab {
            case .media: mediaTab
            case .text: TextPresetsView(model: model)
            }
        }
        .background(Theme.panel)
    }

    private var filteredMedia: [MediaRef] {
        var items = model.project.media
        if !search.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .date: items.sort { $0.importedAt > $1.importedAt }
        case .name: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .type: items.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        }
        return items
    }

    private var mediaTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.importPanel()
                } label: {
                    Label("Importer", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .help("Importer des vidéos, sons ou images (⌘I)")
                TextField("Rechercher", text: $search)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(MediaSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Trier")
            }
            .padding(10)

            if model.project.media.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Glissez ici vos vidéos, sons et images").multilineTextAlignment(.center)
                    Text("ou cliquez sur Importer").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
                .padding(12)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 12) {
                        ForEach(filteredMedia) { media in
                            MediaTile(media: media, poster: library.posters[media.id],
                                      used: model.project.isUsed(mediaID: media.id),
                                      missing: library.missing.contains(media.id))
                                .onTapGesture(count: 2) { model.addMediaToTimeline(media.id) }
                                .onDrag { NSItemProvider(object: "rushcut-media:\(media.id.uuidString)" as NSString) }
                                .contextMenu {
                                    Button("Ajouter à la timeline") { model.addMediaToTimeline(media.id) }
                                    if library.missing.contains(media.id) {
                                        Button("Relier le média…") { model.relink(media.id) }
                                    } else {
                                        Button("Afficher dans le Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([media.url])
                                        }
                                    }
                                    Divider()
                                    Button("Retirer de la bibliothèque") { model.removeMedia(media.id) }
                                        .disabled(model.project.isUsed(mediaID: media.id))
                                }
                        }
                    }
                    .padding(10)
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2).padding(4)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { urls in
                Task { await model.importMedia(urls) }
            }
            return true
        }
    }
}

/// Lit les fichiers glissés depuis le Finder.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(urls) }
    }
}

struct MediaTile: View {
    let media: MediaRef
    let poster: CGImage?
    let used: Bool
    let missing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4))
                if let poster {
                    Image(nsImage: poster.nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                } else {
                    Image(systemName: media.kind == .audio ? "waveform" : (media.kind == .image ? "photo" : "film"))
                        .font(.system(size: 26))
                        .foregroundStyle(media.kind == .audio ? Theme.audio : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if media.kind != .image || media.isAnimated {
                    Text(media.duration.shortLabel)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(4)
                }
            }
            .frame(height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(missing ? Theme.missing : Color.clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                if used {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .help("Utilisé dans la timeline")
                }
            }
            .overlay {
                if missing {
                    Label("Introuvable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(4)
                        .background(Capsule().fill(Theme.missing))
                }
            }
            Text(media.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(missing ? Theme.missing : .primary)
        }
        .contentShape(Rectangle())
        .help(missing ? "Fichier introuvable : clic droit > Relier le média…" : "Double-clic : ajouter à la timeline · Glisser : placer où vous voulez")
    }
}

/// Modèles de texte prêts à l'emploi.
struct TextPresetsView: View {
    @ObservedObject var model: EditorModel

    static var presets: [(String, TextContent)] {
        var title = TextContent()
        title.string = "Titre"
        title.fontSize = 0.1
        title.shadowEnabled = true

        var subtitle = TextContent()
        subtitle.string = "Sous-titre"
        subtitle.fontSize = 0.055
        subtitle.bold = false

        var caption = TextContent()
        caption.string = "Texte sur bandeau sombre"
        caption.fontSize = 0.05
        caption.bold = false
        caption.backgroundEnabled = true
        caption.backgroundColor = RGBA(r: 0, g: 0, b: 0, a: 0.7)

        var outlined = TextContent()
        outlined.string = "TEXTE CONTOURÉ"
        outlined.fontSize = 0.08
        outlined.strokeEnabled = true
        outlined.strokeWidth = 0.1

        var quote = TextContent()
        quote.string = "« Une citation »"
        quote.fontName = "Georgia"
        quote.italic = true
        quote.bold = false
        quote.fontSize = 0.06

        var callout = TextContent()
        callout.string = "À retenir !"
        callout.fontSize = 0.06
        callout.color = RGBA(r: 0.1, g: 0.1, b: 0.1)
        callout.backgroundEnabled = true
        callout.backgroundColor = RGBA(r: 1, g: 0.82, b: 0.2, a: 1)
        callout.backgroundCornerRadius = 0.4

        return [("Titre", title), ("Sous-titre", subtitle), ("Bandeau sombre", caption),
                ("Contour", outlined), ("Citation", quote), ("Encadré", callout)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cliquez sur un modèle pour l'ajouter à la tête de lecture. Modifiez ensuite le texte dans l'inspecteur.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(Self.presets, id: \.0) { preset in
                        Button {
                            model.addText(preset.1)
                        } label: {
                            TextPresetPreview(text: preset.1, label: preset.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
    }
}

struct TextPresetPreview: View {
    let text: TextContent
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55))
                if let image = TextRenderer.render(text, canvas: CGSize(width: 320, height: 180)) {
                    Image(nsImage: image.nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                }
            }
            .frame(height: 66)
            Text(label).font(.caption)
        }
        .contentShape(Rectangle())
    }
}
