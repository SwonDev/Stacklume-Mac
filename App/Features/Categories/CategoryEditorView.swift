import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import StacklumeCore
import StacklumeDesignSystem

/// Alta y edición de una categoría (nombre, icono, color, jerarquía y portada).
/// Paridad con el editor del iPhone, adaptado a macOS (`.fileImporter` en vez de
/// PhotosPicker; `Image(platformImage:)` para la previsualización).
struct CategoryEditorView: View {
    enum Mode: Identifiable {
        case create
        case edit(BookmarkCategory)
        var id: String { switch self { case .create: "create"; case .edit(let c): c.id.uuidString } }
    }
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil }, sort: \BookmarkCategory.order)
    private var all: [BookmarkCategory]

    @State private var name = ""
    @State private var icon = "folder.fill"
    @State private var colorHex = ColorPresets.all[0]
    @State private var parentID: UUID?
    @State private var coverData: Data?
    @State private var showCoverImporter = false
    @State private var didLoad = false

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Categorías que pueden ser padre: todas menos la propia y sus descendientes,
    /// para no crear ciclos en la jerarquía (igual que el iPhone).
    private var parentOptions: [BookmarkCategory] {
        guard case let .edit(current) = mode else { return all }
        var forbidden: Set<UUID> = [current.id]
        var stack = current.children
        while let c = stack.popLast() {
            guard forbidden.insert(c.id).inserted else { continue }
            stack.append(contentsOf: c.children)
        }
        return all.filter { !forbidden.contains($0.id) }
    }

    var body: some View {
        EditorScaffold(title: isEditing ? "Editar categoría" : "Nueva categoría",
                       confirmTitle: isEditing ? "Guardar" : "Crear",
                       canConfirm: canSave,
                       onCancel: { dismiss() },
                       onConfirm: save) {
            Form {
                Section("Nombre") {
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(Color(hex: colorHex))
                            .accessibilityHidden(true)
                        TextField("Nombre de la categoría", text: $name)
                    }
                }
                Section("Color") { ColorSwatchPicker(selection: $colorHex) }
                Section("Icono") { IconPicker(selection: $icon, tint: Color(hex: colorHex)) }
                if !parentOptions.isEmpty {
                    Section {
                        Picker("Categoría padre", selection: $parentID) {
                            Text("Ninguna").tag(UUID?.none)
                            ForEach(parentOptions) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    } header: {
                        Text("Anidar en")
                    } footer: {
                        Text("Convierte esta categoría en subcolección de otra.")
                    }
                }
                Section {
                    coverPicker
                } header: {
                    Text("Portada")
                } footer: {
                    Text("Imagen opcional. Si la añades, la colección la mostrará en lugar del icono.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fileImporter(isPresented: $showCoverImporter,
                          allowedContentTypes: [.image]) { result in
                handlePickedCover(result)
            }
        }
        .frame(width: 460, height: 640)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if case .edit(let c) = mode {
                name = c.name; icon = c.icon; colorHex = c.colorHex
                parentID = c.parent?.id
                coverData = c.coverImageData
            }
        }
    }

    /// Selector de portada: muestra la imagen elegida (o un botón) y permite
    /// reemplazarla o quitarla.
    @ViewBuilder
    private var coverPicker: some View {
        if let coverData, let image = PlatformImage(data: coverData) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                // Patrón caja fija + imagen overlay: la imagen nunca puede ensanchar
                // el contenedor con portadas de relación de aspecto inesperada.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .overlay {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Button { showCoverImporter = true } label: {
                        Label("Cambiar portada", systemImage: "photo")
                    }
                    .themedHelp("Reemplazar la imagen de portada")
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.snappy) { self.coverData = nil }
                    } label: {
                        Label("Quitar", systemImage: "trash")
                    }
                    .themedHelp("Quitar la portada de la colección")
                }
                .stacklumeFont(.subheadline)
            }
        } else {
            Button { showCoverImporter = true } label: {
                Label("Elegir portada…", systemImage: "photo.on.rectangle.angled")
            }
            .themedHelp("Añadir una imagen de portada a la colección")
        }
    }

    /// Carga la imagen elegida, la reduce a un JPEG ligero (máx. 800 px) y la guarda
    /// como `coverImageData`. Evita inflar el almacén y la memoria.
    private func handlePickedCover(_ result: Result<URL, Error>) {
        guard case let .success(fileURL) = result else { return }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? BoundedFileReader.read(
            fileURL,
            maximumBytes: 32 * 1_024 * 1_024
        ), let jpeg = CoverImage.downscaledJPEG(data, maxDimension: 800) else { return }
        withAnimation(.snappy) { coverData = jpeg }
    }

    private func save() {
        let parent = parentID.flatMap { id in all.first { $0.id == id } }
        switch mode {
        case .create:
            // Toda alta pasa por el resolutor canónico para no crear sinónimos duplicados desde
            // editores distintos. Solo personaliza la entidad cuando realmente es nueva.
            if EntityResolver.existingCategory(name, in: context) == nil,
               let category = EntityResolver.category(
                name, in: context, colorHex: colorHex, icon: icon) {
                category.order = all.count
                category.parent = parent
                category.coverImageData = coverData
            }
        case .edit(let c):
            c.name = name; c.icon = icon; c.colorHex = colorHex
            c.parent = parent
            c.coverImageData = coverData
            c.updatedAt = Date()
        }
        context.saveLogging()
        dismiss()
    }
}
