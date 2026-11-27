import SwiftUI
import AppKit
import AVFoundation

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
        if let i = args.firstIndex(of: "--tour"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                await runTour(dir)
            }
            return
        }
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
              let view = window.contentView else { return }
        Log.info("Vues : \(describe(view, depth: 0, maxDepth: 7).joined(separator: " | "))")
        // 1. Rendu des calques (contenu SwiftUI compris).
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                               bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let layer = view.layer {
            ctx.scaleBy(x: scale, y: scale)
            if !view.isFlipped {
                // Les calques AppKit sont déjà dans le bon sens.
            }
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
            if let image = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        // 2. Rendu classique des vues.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let alt = url.deletingPathExtension().appendingPathExtension("vues.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: alt)
        }
    }

    /// Fenêtre de feuille (export, réglages…) ouverte au-dessus de la fenêtre principale.
    static func captureSheet(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) ?? NSApp.windows.first(where: { $0.sheetParent != nil }),
              let view = window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        if let image = ctx.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Visite guidée : ouvre chaque onglet et chaque panneau, et enregistre une image de chacun.
    static func runTour(_ dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        guard let editor = AppModel.shared.editor else {
            capture(to: dir.appendingPathComponent("01-accueil.png"))
            NSApp.terminate(nil)
            return
        }
        // Image de l'aperçu (la vidéo d'un AVPlayerLayer n'apparaît pas dans une capture des calques).
        editor.playback.seek(to: RTime(seconds: 1.5))
        if let built = try? await CompositionBuilder.build(project: editor.project, renderSize: CGSize(width: 1280, height: 720)) {
            let generator = AVAssetImageGenerator(asset: built.asset)
            generator.videoComposition = built.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            editor.stillFrame = try? await generator.image(at: RTime(seconds: 1.5).cmTime).image
        }
        let tracks = editor.project.tracks
        let video = tracks.first { $0.isMain }?.clips.first { editor.project.media($0.mediaID)?.kind == .video }
        let music = tracks.first { $0.kind == .audio }?.clips.first
        let title = tracks.filter { $0.kind == .text }.flatMap(\.clips).first { $0.text?.isSubtitle != true }
        var n = 2
        func shot(_ name: String, delay: Double = 1.5) async {
            await wait(delay)
            capture(to: dir.appendingPathComponent(String(format: "%02d-%@.png", n, name)))
            n += 1
        }
        editor.selection = []
        await shot("montage", delay: 2)
        for tab in LibraryTab.allCases {
            editor.libraryTab = tab
            await shot("bibliotheque-\(tab.rawValue)", delay: tab == .media ? 1.5 : 4)
        }
        editor.libraryTab = .effects
        if let video {
            editor.selection = [video.id]
            for tab in [InspectorTab.base, .animation, .vitesse, .ajuster, .masque, .effets, .incrustation, .auto] {
                editor.inspectorTab = tab
                await shot("inspecteur-\(tab.rawValue)", delay: tab == .animation ? 3.5 : 1.5)
            }
        }
        if let title {
            editor.selection = [title.id]
            editor.inspectorTab = .texte
            editor.libraryTab = .text
            await shot("inspecteur-texte", delay: 2.5)
        }
        if let music {
            editor.selection = [music.id]
            editor.inspectorTab = .audio
            editor.libraryTab = .audio
            await shot("inspecteur-audio")
        }
        editor.selection = []
        func sheet(_ name: String, _ open: () -> Void, _ close: () -> Void) async {
            open()
            await wait(2)
            captureSheet(to: dir.appendingPathComponent(String(format: "%02d-%@.png", n, name)))
            n += 1
            close()
            await wait(1)
        }
        await sheet("export", { editor.exportPresented = true }, { editor.exportPresented = false })
        await sheet("historique", { editor.versionsPresented = true }, { editor.versionsPresented = false })
        await sheet("conversion", { editor.ffmpegPresented = true }, { editor.ffmpegPresented = false })
        await sheet("assistant", { editor.assistantPresented = true }, { editor.assistantPresented = false })
        await sheet("modele", { editor.templatePresented = true }, { editor.templatePresented = false })
        editor.stillFrame = nil
        AppModel.shared.closeProject()
        await wait(2)
        capture(to: dir.appendingPathComponent(String(format: "%02d-accueil-avec-projet.png", n)))
        n += 1
        AppModel.shared.showNewProject = true
        await wait(2)
        captureSheet(to: dir.appendingPathComponent(String(format: "%02d-nouveau-projet.png", n)))
        AppModel.shared.showNewProject = false
        await wait(1)
        Log.info("Visite terminée : \(n) captures")
        NSApp.terminate(nil)
    }

    private static func describe(_ view: NSView, depth: Int, maxDepth: Int) -> [String] {
        var lines = ["\(String(repeating: ".", count: depth))\(type(of: view)) \(Int(view.frame.width))×\(Int(view.frame.height))"]
        guard depth < maxDepth else { return lines }
        for sub in view.subviews.prefix(6) {
            lines.append(contentsOf: describe(sub, depth: depth + 1, maxDepth: maxDepth))
        }
        return lines
    }
}
