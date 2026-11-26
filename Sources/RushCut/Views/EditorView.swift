import SwiftUI
import AppKit

/// Écran de montage : bibliothèque, lecteur, inspecteur en haut, timeline en bas.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if model.previewOnly {
                PlayerPanel(model: model, playback: model.playback, library: model.library)
            } else {
                VSplitView {
                    HSplitView {
                        LibraryPanel(model: model, library: model.library)
                            .frame(minWidth: 250, idealWidth: 320, maxWidth: 520)
                        PlayerPanel(model: model, playback: model.playback, library: model.library)
                            .frame(minWidth: 420)
                        InspectorPanel(model: model)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 460)
                    }
                    .frame(minHeight: 320, idealHeight: 520)
                    TimelinePanel(model: model, library: model.library)
                        .frame(minHeight: 230, idealHeight: 330)
                }
            }
        }
        .navigationTitle(model.project.name)
        .navigationSubtitle(statusText)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.closeProject()
                } label: {
                    Label("Accueil", systemImage: "house")
                }
                .help("Revenir à l'accueil (le projet est enregistré)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.undo()
                } label: { Label("Annuler", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help(model.undoName.map { "Annuler « \($0) » (⌘Z)" } ?? "Annuler (⌘Z)")
                Button {
                    model.redo()
                } label: { Label("Rétablir", systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help(model.redoName.map { "Rétablir « \($0) » (⇧⌘Z)" } ?? "Rétablir (⇧⌘Z)")
                Button {
                    model.previewOnly.toggle()
                } label: { Label("Aperçu en grand", systemImage: model.previewOnly ? "rectangle.split.3x1" : "rectangle.expand.vertical") }
                    .help("Aperçu en grand (⇧⌘F)")
                Button {
                    model.exportPresented = true
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .help("Exporter la vidéo (⌘E)")
            }
        }
        .sheet(isPresented: $model.exportPresented) {
            ExportSheet(model: model)
        }
    }

    private var statusText: String {
        let s = model.project.settings
        var parts = ["\(s.width)×\(s.height)", "\(s.frameRate) i/s"]
        if model.importInProgress { parts.append("Import en cours…") }
        if model.isDirty {
            parts.append("Modifications non enregistrées")
        } else if let saved = model.lastSaved {
            parts.append("Enregistré à \(saved.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Couleurs de l'application.
enum Theme {
    static let video = Color(red: 0.16, green: 0.42, blue: 0.62)
    static let image = Color(red: 0.13, green: 0.50, blue: 0.48)
    static let audio = Color(red: 0.18, green: 0.52, blue: 0.30)
    static let text = Color(red: 0.48, green: 0.30, blue: 0.70)
    static let missing = Color(red: 0.70, green: 0.16, blue: 0.16)
    static let sticker = Color(red: 0.78, green: 0.46, blue: 0.12)
    static let effect = Color(red: 0.62, green: 0.22, blue: 0.48)
    static let filter = Color(red: 0.30, green: 0.34, blue: 0.62)
    static let playhead = Color(red: 1.0, green: 0.30, blue: 0.30)
    static let panel = Color(nsColor: .underPageBackgroundColor)
}

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
}

/// Champ numérique + curseur, pour l'inspecteur.
struct SliderField: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var unit: String = ""
    var fractionDigits: Int = 0
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: Binding(get: { value }, set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }),
                          format: .number.precision(.fractionLength(0...fractionDigits)))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                }
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { onChange($0) }), in: range)
                .controlSize(.small)
        }
    }
}
