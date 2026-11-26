import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// État global : écran d'accueil ou projet ouvert.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var editor: EditorModel?
    @Published var projects: [ProjectSummary] = []
    @Published var alert: AppAlert?
    @Published var showNewProject = false
    @Published var recoveryURL: URL?

    private init() {}

    func refreshProjects() {
        projects = ProjectStore.listProjects()
    }

    func createProject(name: String, settings: ProjectSettings) {
        do {
            let (_, url) = try ProjectStore.createProject(name: name, settings: settings)
            open(url)
        } catch {
            show(error, title: "Création impossible")
        }
    }

    func open(_ url: URL) {
        if let editor, editor.url == url { return }
        closeProject()
        do {
            let project = try ProjectStore.load(url)
            editor = EditorModel(project: project, url: url)
            ProjectStore.writeSessionLock(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            Log.info("Projet ouvert : \(url.path)")
        } catch {
            show(error, title: "Ouverture impossible")
        }
    }

    func closeProject() {
        guard let editor else { return }
        editor.saveNow()
        editor.teardown()
        self.editor = nil
        ProjectStore.clearSessionLock()
        refreshProjects()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir un projet RushCut"
        panel.prompt = "Ouvrir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectStore.defaultDirectory
        if let type = UTType(ProjectStore.typeIdentifier) { panel.allowedContentTypes = [type, .folder] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == ProjectStore.fileExtension else {
            alert = AppAlert(title: "Ce n'est pas un projet RushCut", message: "Choisissez un dossier se terminant par « .rushcut ».")
            return
        }
        open(url)
    }

    // MARK: - Récupération

    func checkRecovery() {
        if let url = ProjectStore.readSessionLock() {
            recoveryURL = url
        }
    }

    func prepareForQuit() {
        editor?.saveNow()
        ProjectStore.clearSessionLock()
    }

    // MARK: - Gestion des projets

    func duplicate(_ summary: ProjectSummary) {
        do { _ = try ProjectStore.duplicate(summary.url); refreshProjects() } catch { show(error, title: "Duplication impossible") }
    }

    func rename(_ summary: ProjectSummary, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { _ = try ProjectStore.rename(summary.url, to: trimmed); refreshProjects() } catch { show(error, title: "Renommage impossible") }
    }

    func trash(_ summary: ProjectSummary) {
        do { try ProjectStore.trash(summary.url); refreshProjects() } catch { show(error, title: "Suppression impossible") }
    }

    func show(_ error: Error, title: String) {
        Log.error("\(title) : \(error.localizedDescription)")
        alert = AppAlert(title: title, message: error.localizedDescription)
    }
}
