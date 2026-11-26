import SwiftUI
import AppKit

/// Écran d'accueil : nouveau projet et projets récents.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var renaming: ProjectSummary?
    @State private var newName = ""
    @State private var toDelete: ProjectSummary?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                AppLogo()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RushCut").font(.system(size: 30, weight: .bold))
                    Text("Montage vidéo, en local sur votre Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Ouvrir…") { app.openPanel() }
                    .controlSize(.large)
                Button {
                    app.showNewProject = true
                } label: {
                    Label("Nouveau projet", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(28)

            Divider()

            if app.projects.isEmpty {
                ContentUnavailableView {
                    Label("Aucun projet pour l'instant", systemImage: "film.stack")
                } description: {
                    Text("Créez un projet, importez vos vidéos et commencez le montage.")
                } actions: {
                    Button("Nouveau projet") { app.showNewProject = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Projets récents").font(.title3.weight(.semibold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(app.projects) { summary in
                                ProjectCard(summary: summary)
                                    .onTapGesture(count: 2) { app.open(summary.url) }
                                    .contextMenu {
                                        Button("Ouvrir") { app.open(summary.url) }
                                        Button("Renommer…") { newName = summary.name; renaming = summary }
                                        Button("Dupliquer") { app.duplicate(summary) }
                                        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.url]) }
                                        Divider()
                                        Button("Placer dans la corbeille", role: .destructive) { toDelete = summary }
                                    }
                            }
                        }
                        Text("Double-cliquez sur un projet pour l'ouvrir. Clic droit pour le renommer, le dupliquer ou le supprimer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                }
            }
        }
        .onAppear { app.refreshProjects() }
        .sheet(item: $renaming) { summary in
            VStack(alignment: .leading, spacing: 14) {
                Text("Renommer le projet").font(.headline)
                TextField("Nom", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("Annuler") { renaming = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Renommer") {
                        app.rename(summary, to: newName)
                        renaming = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .confirmationDialog("Placer « \(toDelete?.name ?? "") » dans la corbeille ?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Placer dans la corbeille", role: .destructive) {
                if let p = toDelete { app.trash(p) }
                toDelete = nil
            }
            Button("Annuler", role: .cancel) { toDelete = nil }
        } message: {
            Text("Les fichiers vidéo d'origine ne sont pas touchés. Le projet peut être récupéré depuis la corbeille.")
        }
    }
}

struct ProjectCard: View {
    let summary: ProjectSummary
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
                if let url = summary.posterURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovering ? Color.accentColor : Color.white.opacity(0.08), lineWidth: hovering ? 2 : 1))
            Text(summary.name).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(summary.formatLabel)
                Text("·")
                Text(summary.duration.shortLabel)
                Spacer()
                Text(summary.modifiedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Double-cliquez pour ouvrir")
    }
}

/// Création d'un projet : nom, format, fréquence d'images.
struct NewProjectSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Nouveau projet"
    @State private var preset: AspectPreset = .landscape16x9
    @State private var frameRate = 30
    @State private var customWidth = 1920
    @State private var customHeight = 1080

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nouveau projet").font(.title2.weight(.semibold))
            TextField("Nom du projet", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            Text("Format").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(AspectPreset.allCases) { p in
                    Button { preset = p } label: {
                        VStack(spacing: 6) {
                            let (w, h) = p == .custom ? (customWidth, customHeight) : p.size
                            let ratio = CGFloat(w) / CGFloat(max(h, 1))
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(preset == p ? Color.accentColor : Color.secondary, lineWidth: 2)
                                .frame(width: ratio >= 1 ? 44 : 44 * ratio, height: ratio >= 1 ? 44 / ratio : 44)
                                .frame(height: 48)
                            Text(p.label).font(.headline)
                            Text(p.usage).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(preset == p ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if preset == .custom {
                HStack {
                    TextField("Largeur", value: $customWidth, format: .number).frame(width: 90)
                    Text("×")
                    TextField("Hauteur", value: $customHeight, format: .number).frame(width: 90)
                    Text("pixels").foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
            }
            Picker("Images par seconde", selection: $frameRate) {
                ForEach(ProjectSettings.supportedFrameRates, id: \.self) { Text("\($0) i/s").tag($0) }
            }
            .frame(width: 280)

            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Créer le projet") {
                    var settings = ProjectSettings()
                    let (w, h) = preset == .custom ? (customWidth, customHeight) : preset.size
                    settings.width = max(16, min(8192, w / 2 * 2))
                    settings.height = max(16, min(8192, h / 2 * 2))
                    settings.frameRate = frameRate
                    dismiss()
                    app.createProject(name: name, settings: settings)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

/// Logo dessiné (pas d'appel au service d'icônes du système, qui peut bloquer au démarrage).
struct AppLogo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.37, blue: 0.23), Color(red: 0.93, green: 0.13, blue: 0.43)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "play.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 2)
        }
    }
}
