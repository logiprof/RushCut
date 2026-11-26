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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avant les événements « ouvrir » du Finder : sinon le projet ouvert serait pris pour un plantage.
        MainActor.assumeIsolated { AppModel.shared.checkRecovery() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Démarrage de RushCut \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
        FontLibrary.registerImportedFonts()
        MainActor.assumeIsolated {
            KeyboardMonitor.shared.install()
            AppModel.shared.refreshProjects()
            Log.info("Lancement terminé")
            SelfCapture.scheduleIfRequested()
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

/// Diagnostic : `RushCut --capture fichier.png` enregistre l'image de la fenêtre au bout de 8 secondes.
/// Utilisé par la compilation automatique pour vérifier l'interface sans intervention.
@MainActor
enum SelfCapture {
    static func scheduleIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture"), i + 1 < args.count else { return }
        let path = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            MainActor.assumeIsolated { capture(to: URL(fileURLWithPath: path)) }
        }
    }

    static func capture(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        Log.info("Capture : \(windows.count) fenêtre(s) visible(s) : \(windows.map { "\($0.title) \(Int($0.frame.width))×\(Int($0.frame.height))" })")
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
