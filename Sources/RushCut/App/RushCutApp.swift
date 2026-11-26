import SwiftUI
import AppKit

@main
struct RushCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        Window("RushCut", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1280, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { RushCommands(app: app) }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Démarrage de RushCut \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
        FontLibrary.registerImportedFonts()
        MainActor.assumeIsolated {
            KeyboardMonitor.shared.install()
            AppModel.shared.checkRecovery()
            AppModel.shared.refreshProjects()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == ProjectStore.fileExtension }) else { return }
        MainActor.assumeIsolated { AppModel.shared.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.prepareForQuit() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Écran principal : accueil ou montage.
struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if let editor = app.editor {
                EditorView(model: editor)
                    .id(editor.url)
            } else {
                HomeView()
            }
        }
        .sheet(isPresented: $app.showNewProject) {
            NewProjectSheet()
                .environmentObject(app)
        }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("RushCut s'est fermé de façon inattendue",
                            isPresented: Binding(get: { app.recoveryURL != nil }, set: { if !$0 { app.recoveryURL = nil } }),
                            titleVisibility: .visible) {
            Button("Rouvrir le projet") {
                if let url = app.recoveryURL { app.open(url) }
                app.recoveryURL = nil
            }
            Button("Plus tard", role: .cancel) {
                app.recoveryURL = nil
                ProjectStore.clearSessionLock()
            }
        } message: {
            Text("Le projet « \(app.recoveryURL?.deletingPathExtension().lastPathComponent ?? "") » était ouvert. Sa dernière sauvegarde automatique date de moins de 30 secondes avant la fermeture.")
        }
    }
}
