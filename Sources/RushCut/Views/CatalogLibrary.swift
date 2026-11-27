import SwiftUI
import AppKit
import CoreImage

private let tileColumns = [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 8)]

/// Rappel discret de ce que fera un clic.
private struct TargetHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

// MARK: - Effets

struct EffectsLibrary: View {
    @ObservedObject var model: EditorModel
    @State private var category = EffectCategory.lumiere.rawValue
    @State private var search = ""

    private var items: [EffectDef] {
        if !search.isEmpty {
            return EffectCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        return EffectCatalog.all.filter { $0.category.rawValue == category }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Rechercher un effet", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
            CategoryChips(categories: EffectCategory.allCases.map(\.rawValue).filter { c in EffectCatalog.all.contains { $0.category.rawValue == c } },
                          selected: $category)
            TargetHint(text: model.visualSelection.isEmpty
                       ? "Clic : ajoute l'effet sur une piste d'effets (agit sur tout ce qui est dessous)."
                       : "Clic : applique l'effet au clip sélectionné.")
            ScrollView {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    ForEach(items) { def in
                        CatalogTile(key: "effet-\(def.id)", title: def.name,
                                    badge: def.needsSegmentation ? "Sujet" : nil,
                                    animatedFrames: 16,
                                    make: { f, n, base in CatalogThumbnails.effect(def, frame: f, frames: n, base: base) },
                                    action: { model.useEffect(def) })
                            .contextMenu {
                                Button("Ajouter sur une piste d'effets") { model.addEffectClip(def) }
                                if !model.visualSelection.isEmpty {
                                    Button("Appliquer au clip sélectionné") { model.useEffect(def) }
                                }
                            }
                    }
                }
                .padding(10)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Transitions

struct TransitionsLibrary: View {
    @ObservedObject var model: EditorModel
    @State private var category = ""
    @State private var duration = 0.5

    private var categories: [String] {
        var seen: [String] = []
        for t in TransitionCatalog.all where !seen.contains(t.category) { seen.append(t.category) }
        return seen
    }

    var body: some View {
        let target = model.transitionTarget
        VStack(spacing: 8) {
            CategoryChips(categories: categories, selected: Binding(get: { category.isEmpty ? (categories.first ?? "") : category },
                                                                    set: { category = $0 }))
            TargetHint(text: target == nil
                       ? "Placez au moins deux clips sur la piste principale pour ajouter une transition."
                       : "Clic : transition au raccord avant « \(target!.name) ».")
            HStack {
                Text("Durée").font(.caption)
                Slider(value: $duration, in: 0.1...3).controlSize(.small)
                Text(String(format: "%.1f s", duration)).font(.caption.monospacedDigit()).frame(width: 40)
            }
            .padding(.horizontal, 10)
            HStack {
                Button("Aucune") { model.useTransition(nil) }
                Spacer()
                Button("Appliquer à tous les raccords") {
                    let type = target?.transitionIn?.type ?? "fondu"
                    model.useTransitionEverywhere(type, duration: RTime(seconds: duration))
                }
                .disabled(target == nil)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            ScrollView {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    let current = category.isEmpty ? (categories.first ?? "") : category
                    ForEach(TransitionCatalog.all.filter { $0.category == current }) { def in
                        CatalogTile(key: "transition-\(def.id)", title: def.name,
                                    isSelected: target?.transitionIn?.type == def.id,
                                    animatedFrames: 18,
                                    make: { f, n, base in CatalogThumbnails.transition(def, frame: f, frames: n, base: base) },
                                    action: {
                                        model.useTransition(def)
                                        if let id = model.transitionTarget?.id { model.setTransitionDuration(id, seconds: duration) }
                                    })
                    }
                }
                .padding(10)
            }
        }
        .padding(.top, 8)
        .disabled(target == nil)
    }
}

// MARK: - Filtres

struct FiltersLibrary: View {
    @ObservedObject var model: EditorModel
    @State private var category = ""

    private var categories: [String] {
        var seen: [String] = []
        for f in FilterCatalog.all where !seen.contains(f.category) { seen.append(f.category) }
        seen.append("Mes LUT")
        return seen
    }

    var body: some View {
        let current = category.isEmpty ? (categories.first ?? "") : category
        let selectedFilter = model.visualSelection.first?.filter?.id
        VStack(spacing: 8) {
            CategoryChips(categories: categories, selected: Binding(get: { current }, set: { category = $0 }))
            TargetHint(text: model.visualSelection.isEmpty
                       ? "Clic : ajoute le filtre sur une piste d'effets."
                       : "Clic : applique le filtre au clip sélectionné.")
            ScrollView {
                if current == "Mes LUT" {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Importer un LUT (.cube)…") { model.importLUTPanel() }
                            .controlSize(.small)
                        Text("Les LUT 3D au format .cube (étalonnage de caméra, looks de cinéma) s'appliquent comme un filtre, avec intensité réglable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                }
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    if current == "Mes LUT" {
                        ForEach(LUTLibrary.installed, id: \.self) { name in
                            CatalogTile(key: "lut-\(name)", title: (name as NSString).deletingPathExtension,
                                        isSelected: selectedFilter == LUTLibrary.prefix + name,
                                        make: { _, _, base in LUTLibrary.apply(name: name, to: base, intensity: 1) },
                                        action: { model.useLUT(name) })
                        }
                    } else {
                        ForEach(FilterCatalog.all.filter { $0.category == current }) { def in
                            CatalogTile(key: "filtre-\(def.id)", title: def.name, isSelected: selectedFilter == def.id,
                                        make: { _, _, base in FilterCatalog.render(def.recipe, base, frame: 0) },
                                        action: { model.useFilter(def) })
                        }
                    }
                }
                .padding(10)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Autocollants

struct StickersLibrary: View {
    @ObservedObject var model: EditorModel
    @State private var category = ""
    @State private var color = CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)

    private var categories: [String] {
        var seen: [String] = []
        for s in StickerCatalog.all where !seen.contains(s.category) { seen.append(s.category) }
        return seen
    }

    var body: some View {
        let current = category.isEmpty ? (categories.first ?? "") : category
        let rgba = RGBA(cgColor: color)
        VStack(spacing: 8) {
            CategoryChips(categories: categories, selected: Binding(get: { current }, set: { category = $0 }))
            HStack {
                ColorPicker("Couleur", selection: $color, supportsOpacity: false)
                Spacer()
                Text("Clic : ajoute à la tête de lecture").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 90), spacing: 8)], spacing: 8) {
                    ForEach(StickerCatalog.all.filter { $0.category == current }) { def in
                        Button { model.addSticker(def, color: rgba) } label: {
                            VStack(spacing: 2) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                                    if let image = StickerCatalog.render(def.id, color: rgba, canvas: CGSize(width: 220, height: 220)) {
                                        Image(nsImage: NSImage(cgImage: image, size: .zero))
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .padding(6)
                                    }
                                }
                                .frame(height: 58)
                                Text(def.name).font(.system(size: 9)).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(def.name)
                    }
                }
                .padding(10)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Textes

struct TextStylesLibrary: View {
    @ObservedObject var model: EditorModel
    @State private var category = ""

    private var categories: [String] {
        var seen: [String] = []
        for s in TextStyleCatalog.all where !seen.contains(s.category) { seen.append(s.category) }
        return seen
    }

    var body: some View {
        let current = category.isEmpty ? (categories.first ?? "") : category
        VStack(spacing: 8) {
            Button {
                model.addText(TextContent())
            } label: {
                Label("Ajouter un texte", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 10)
            CategoryChips(categories: categories, selected: Binding(get: { current }, set: { category = $0 }))
            TargetHint(text: "Clic sur un style : ajoute un texte à la tête de lecture, ou change le style du texte sélectionné.")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(TextStyleCatalog.all.filter { $0.category == current }) { style in
                        Button { model.useTextStyle(style) } label: {
                            TextStylePreview(style: style)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                BrandKitSection(model: model)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .padding(.top, 8)
    }
}

struct TextStylePreview: View {
    let style: TextStyleDef
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.32))
                if let image {
                    Image(nsImage: NSImage(cgImage: image, size: .zero))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            }
            .frame(height: 62)
            Text(style.name).font(.system(size: 10)).lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: style.id) {
            if let cached = TextStylePreview.cache[style.id] { image = cached; return }
            let rendered = TextRenderer.render(style.content, canvas: CGSize(width: 360, height: 200))
            TextStylePreview.cache[style.id] = rendered
            image = rendered
        }
    }

    @MainActor static var cache: [String: CGImage] = [:]
}

extension EditorModel {
    /// Change le style du texte sélectionné (en gardant ses mots), ou ajoute un nouveau texte.
    func useTextStyle(_ style: TextStyleDef) {
        if let clip = singleSelection, var text = clip.text {
            let string = text.string, words = text.words, animation = text.animation, subtitle = text.isSubtitle
            text = style.content
            text.string = string
            text.words = words
            text.animation = animation
            text.isSubtitle = subtitle
            updateClip(clip.id, "Style « \(style.name) »") { $0.text = text }
        } else {
            addText(style.content)
        }
    }
}
