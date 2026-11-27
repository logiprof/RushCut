import SwiftUI
import AppKit
import CoreText

/// Vrai quand l'utilisateur tape dans un champ de texte : les raccourcis de montage lui cèdent la place.
enum TextFocus {
    @MainActor static var isEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    /// Rend le clavier au montage (après un clic dans la timeline ou l'aperçu).
    @MainActor static func release() {
        if isEditing { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// Menus de l'application (Fichier, Édition, Clip, Timeline, Présentation).
struct RushCommands: Commands {
    @ObservedObject var app: AppModel

    private var editor: EditorModel? { app.editor }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouveau projet…") { app.showNewProject = true }
                .keyboardShortcut("n")
            Button("Ouvrir un projet…") { app.openPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("Importer des médias…") { editor?.importPanel() }
                .keyboardShortcut("i")
                .disabled(editor == nil)
            Divider()
            Button("Fermer le projet") { app.closeProject() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Enregistrer") { editor?.saveNow() }
                .keyboardShortcut("s")
                .disabled(editor == nil)
            Button("Exporter…") { editor?.exportPresented = true }
                .keyboardShortcut("e")
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Annuler") {
                if TextFocus.isEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { editor?.undo() }
            }
            .keyboardShortcut("z")
            Button("Rétablir") {
                if TextFocus.isEditing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { editor?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Couper") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button("Copier") {
                if TextFocus.isEditing || editor == nil { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { editor?.copySelection() }
            }
            .keyboardShortcut("c")
            Button("Coller") {
                if TextFocus.isEditing || editor == nil { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } else { editor?.paste() }
            }
            .keyboardShortcut("v")
            Button("Dupliquer") { editor?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(editor == nil)
            Divider()
            Button("Tout sélectionner") {
                if TextFocus.isEditing || editor == nil { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } else { editor?.selectAll() }
            }
            .keyboardShortcut("a")
        }
        CommandMenu("Clip") {
            Button("Couper à la tête de lecture") { editor?.splitAtPlayhead() }
                .keyboardShortcut("b")
                .disabled(editor == nil)
            Button("Supprimer à gauche de la tête de lecture (Q)") { editor?.trimToPlayhead(keepRight: true) }
                .disabled(editor == nil)
            Button("Supprimer à droite de la tête de lecture (W)") { editor?.trimToPlayhead(keepRight: false) }
                .disabled(editor == nil)
            Divider()
            Button("Détacher l'audio") { editor?.detachAudio() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Supprimer (⌫)") { editor?.deleteSelection() }
                .disabled(editor == nil)
            Divider()
            Button("Grouper") { editor?.groupSelection() }
                .keyboardShortcut("g")
                .disabled((editor?.selection.count ?? 0) < 2)
            Button("Dissocier") { editor?.ungroupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(editor?.selection.isEmpty ?? true)
            Button("Créer un clip composé") { editor?.makeCompound() }
                .disabled((editor?.selection.count ?? 0) < 2)
            Button("Décomposer le clip composé") { if let id = editor?.singleSelection?.id { editor?.breakCompound(id) } }
                .disabled(editor?.singleSelection?.compoundSource == nil)
            Divider()
            Button("Copier les attributs") { editor?.copyAttributes() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(editor?.singleSelection == nil)
            Button("Coller les attributs") { editor?.pasteAttributes() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(editor?.attributeClipboard == nil)
        }
        CommandMenu("Outils") {
            Button("Supprimer les silences du clip") { if let id = editor?.singleSelection?.id { editor?.removeSilences(id) } }
                .disabled(editor?.singleSelection == nil)
            Button("Image figée à la tête de lecture") { if let id = editor?.singleSelection?.id { editor?.freezeFrame(id) } }
                .disabled(editor?.singleSelection == nil)
            Button("Lire le clip à l'envers") { if let id = editor?.singleSelection?.id { editor?.reverseClip(id) } }
                .disabled(editor?.singleSelection == nil)
            Button("Remplacer le clip…") { if let id = editor?.singleSelection?.id { editor?.replaceClipPanel(id) } }
                .disabled(editor?.singleSelection == nil)
            Button("Suivre le mouvement (calque sur la vidéo)") { if let id = editor?.singleSelection?.id { editor?.trackMotion(id) } }
                .disabled(editor?.singleSelection == nil)
            Divider()
            Button("Enregistrer l'écran…") { editor?.screenRecordingPresented = true }
                .disabled(editor == nil)
            Button("Enregistrer avec la caméra…") { editor?.webcamPresented = true }
                .disabled(editor == nil)
            Button("Assistant de rédaction (Apple Intelligence)…") { editor?.assistantPresented = true }
                .disabled(editor == nil)
            Button("Importer un LUT (.cube)…") { editor?.importLUTPanel() }
                .disabled(editor == nil)
            Button("Enregistrer comme modèle…") { editor?.templatePresented = true }
                .disabled(editor == nil)
            Toggle("Utiliser des proxys pour l'aperçu (vidéos 4K)", isOn: Binding(get: { editor?.useProxies ?? false }, set: { editor?.setUseProxies($0) }))
                .disabled(editor == nil)
            Divider()
            Button("Rassembler les médias dans le projet") { editor?.collectMedia() }
                .disabled(editor == nil)
            Button("Historique des versions…") { editor?.versionsPresented = true }
                .disabled(editor == nil)
            Button("Module de conversion (FFmpeg)…") { editor?.pendingConversion = []; editor?.ffmpegPresented = true }
                .disabled(editor == nil)
        }
        CommandMenu("Timeline") {
            Button("Lecture / pause (Espace)") { editor?.playback.togglePlay() }
                .disabled(editor == nil)
            Button("Ajouter un marqueur (M)") { editor?.addMarker() }
                .disabled(editor == nil)
            Divider()
            Toggle("Aimantation (N)", isOn: Binding(get: { editor?.snapping ?? true }, set: { editor?.snapping = $0 }))
                .disabled(editor == nil)
            Toggle("Piste principale magnétique", isOn: Binding(get: { editor?.magneticMain ?? true }, set: { editor?.magneticMain = $0 }))
                .disabled(editor == nil)
            Divider()
            Button("Zoom avant") { editor?.zoom(by: 1.5) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom arrière") { editor?.zoom(by: 1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil)
            Button("Ajuster à la fenêtre (⇧Z)") { editor?.zoomToFit() }
                .disabled(editor == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Aperçu en grand") { editor?.previewOnly.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Raccourcis clavier de RushCut") {
                app.alert = AppAlert(title: "Raccourcis clavier", message: KeyboardMonitor.helpText)
            }
        }
    }
}

/// Raccourcis à une touche (Espace, J/K/L, flèches, Q, W, M, N, ⌫, ⇧Z), actifs hors saisie de texte.
@MainActor
final class KeyboardMonitor {
    static let shared = KeyboardMonitor()
    private var monitor: Any?

    static let helpText = """
    Espace : lecture / pause
    J / K / L : arrière, pause, avant (appuis répétés : 2×, 4×)
    ← / → : image précédente / suivante
    ⌘B : couper à la tête de lecture
    Q / W : supprimer à gauche / à droite de la tête de lecture
    ⌫ : supprimer (la piste principale se referme)
    ⌘Z / ⇧⌘Z : annuler / rétablir
    ⌘C / ⌘V / ⌘D : copier / coller / dupliquer
    M : ajouter un marqueur
    N : aimantation oui / non
    ⌘+ / ⌘− / ⇧Z : zoom timeline avant / arrière / ajuster
    ⌘I : importer · ⌘E : exporter · ⌘S : enregistrer
    ⇧⌘F : aperçu en grand
    """

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { KeyboardMonitor.shared.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let editor = AppModel.shared.editor,
              let window = NSApp.keyWindow, window.attachedSheet == nil, !window.isSheet,
              !TextFocus.isEditing else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty || mods == [.shift] else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, key, mods == [.shift]) {
        case (49, _, false): editor.playback.togglePlay()
        case (123, _, _): editor.playback.step(frames: mods == [.shift] ? -10 : -1)
        case (124, _, _): editor.playback.step(frames: mods == [.shift] ? 10 : 1)
        case (51, _, false), (117, _, false): editor.deleteSelection()
        case (_, "j", false): editor.playback.shuttle(-1)
        case (_, "k", false): editor.playback.shuttle(0)
        case (_, "l", false): editor.playback.shuttle(1)
        case (_, "q", false): editor.trimToPlayhead(keepRight: true)
        case (_, "w", false): editor.trimToPlayhead(keepRight: false)
        case (_, "m", false): editor.addMarker()
        case (_, "i", false): editor.setInPoint()
        case (_, "o", false): editor.setOutPoint()
        case (_, "x", false): editor.clearInOut()
        case (_, "n", false): editor.snapping.toggle()
        case (_, "z", true): editor.zoomToFit()
        case (53, _, false): editor.selection.removeAll()
        default: return event
        }
        return nil
    }
}

/// Polices importées par l'utilisateur (copiées dans ~/Library/Application Support/RushCut/Polices).
enum FontLibrary {
    static func registerImportedFonts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.fonts, includingPropertiesForKeys: nil) else { return }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    @MainActor static func importFonts() -> [String] {
        let panel = NSOpenPanel()
        panel.title = "Importer des polices"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.font]
        guard panel.runModal() == .OK else { return [] }
        var families: [String] = []
        for url in panel.urls {
            let target = AppPaths.fonts.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { continue }
            CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(target as CFURL) as? [CTFontDescriptor] {
                for d in descriptors {
                    if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                        families.append(family)
                    }
                }
            }
        }
        return families
    }

    @MainActor static var families: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }
}

/// Réglages : caches et journaux.
struct SettingsView: View {
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("Caches") {
                LabeledContent("Dossier", value: AppPaths.caches.path)
                LabeledContent("Taille", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Button("Vider les caches") {
                    try? FileManager.default.removeItem(at: AppPaths.caches)
                    ImageSourceCache.shared.removeAll()
                    AppPaths.ensure(AppPaths.caches)
                    cacheSize = AppPaths.directorySize(AppPaths.caches)
                }
                Text("Les caches (miniatures, fichiers temporaires) peuvent être supprimés sans perte : ils sont recréés au besoin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Projets") {
                LabeledContent("Dossier des projets", value: ProjectStore.defaultDirectory.path)
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.defaultDirectory]) }
            }
            Section("Diagnostic") {
                LabeledContent("Journal", value: AppPaths.logs.path)
                Button("Afficher le journal") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logs]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
        .onAppear { cacheSize = AppPaths.directorySize(AppPaths.caches) }
    }
}
