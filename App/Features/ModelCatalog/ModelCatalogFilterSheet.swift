import SwiftUI
import StacklumeDesignSystem

struct ModelCatalogFilterSheet: View {
    let provider: ModelCatalogProvider
    let connected: Bool
    let taxonomy: [ModelCatalogTaxonomy]
    let taxonomyError: String?
    let isTaxonomyLoading: Bool
    let onApply: (ModelCatalogFilters) -> Void
    @State private var filters: ModelCatalogFilters
    @State private var taxonomyKind = "pipeline_tag"
    @State private var taxonomyQuery = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    init(provider: ModelCatalogProvider, filters: ModelCatalogFilters, connected: Bool, taxonomy: [ModelCatalogTaxonomy], taxonomyError: String?, isTaxonomyLoading: Bool, onApply: @escaping (ModelCatalogFilters) -> Void) {
        self.provider = provider; self.connected = connected
        self.taxonomy = taxonomy; self.taxonomyError = taxonomyError; self.isTaxonomyLoading = isTaxonomyLoading
        self.onApply = onApply; _filters = State(initialValue: filters)
    }

    var body: some View {
        EditorScaffold(title: "Filtros de \(provider.title)", confirmTitle: "Aplicar filtros", onCancel: { dismiss() }, onConfirm: { onApply(filters) }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ModelCatalogFormSection("Búsqueda y orden") {
                        ModelCatalogField("Nombre o identificador", text: $filters.query)
                        ModelCatalogField(provider == .huggingFace ? "Autor u organización" : "Nombre del creador", text: $filters.author)
                        ModelCatalogPicker("Orden", selection: $filters.sort) {
                            ForEach(ModelCatalogFilterOptions.sorts(for: provider), id: \.value) { option in Text(option.title).tag(option.value) }
                        }
                        ModelCatalogPicker("Resultados por petición", selection: $filters.pageSize) {
                            ForEach(ModelCatalogResultWindow.pageSizes, id: \.self) { Text(String($0)).tag($0) }
                        }
                        if provider == .huggingFace { Toggle("Orden descendente", isOn: $filters.descending) }
                        else {
                            ModelCatalogPicker("Periodo", selection: $filters.period) {
                                Text("Todo el tiempo").tag("AllTime")
                                Text("Año").tag("Year"); Text("Mes").tag("Month")
                                Text("Semana").tag("Week"); Text("Día").tag("Day")
                            }
                        }
                    }
                    if provider == .huggingFace { huggingFaceFilters } else { civitaiFilters }
                    if provider == .huggingFace {
                        ModelCatalogFormSection("Clasificación declarada") {
                            ModelCatalogPicker("Contenido", selection: $filters.adultFilter) { ForEach(ModelCatalogAdultFilter.allCases, id: \.self) { Text($0.title).tag($0) } }
                            Text("Hugging Face no publica la escala NSFW de Civitai. Aquí se filtran las etiquetas declaradas nsfw y not-for-all-audiences sobre la página recibida; no certifica el contenido de las muestras.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        }
                    }
                    ModelCatalogFormSection {
                        Button("Restablecer filtros") { filters = ModelCatalogFilters() }.stacklumeButton(prominent: false)
                        Text("Los filtros se consultan en el proveedor. Los campos con varios valores aceptan comas.")
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .background(palette.background)
        }
        .frame(minWidth: 340, idealWidth: 560, maxWidth: 640, minHeight: 420, idealHeight: 680, maxHeight: 780)
    }

    @ViewBuilder private var huggingFaceFilters: some View {
        ModelCatalogFormSection("Tarea, formato y licencia") {
            ModelCatalogField("Tarea", text: $filters.task)
            ModelCatalogField("Bibliotecas o formatos", text: $filters.library)
            ModelCatalogField("Etiquetas", text: $filters.tags)
            ModelCatalogField("Licencias", text: $filters.license)
            ModelCatalogField("Idiomas", text: $filters.language)
            ModelCatalogField("Datasets de entrenamiento", text: $filters.datasets)
            ModelCatalogPicker("Acceso restringido", selection: $filters.gated) {
                Text("Cualquiera").tag(""); Text("Solo restringidos").tag("true"); Text("Sin restricción").tag("false")
            }
        }
        ModelCatalogFormSection("Ejecución y tamaño") {
            ModelCatalogField("Aplicaciones (ollama, llama.cpp…)", text: $filters.apps)
            ModelCatalogField("Proveedores de inferencia", text: $filters.inferenceProviders)
            ModelCatalogField("Parámetros (min:6B,max:128B)", text: $filters.parameters)
            Toggle("Disponible en un proveedor de inferencia", isOn: $filters.warm)
        }
        ModelCatalogFormSection("Taxonomía oficial de Hugging Face") {
            ModelCatalogPicker("Tipo", selection: $taxonomyKind) {
                Text("Tareas").tag("pipeline_tag"); Text("Bibliotecas").tag("library")
                Text("Licencias").tag("license"); Text("Idiomas").tag("language")
                Text("Datasets").tag("dataset"); Text("Otras etiquetas").tag("other")
            }
            ModelCatalogField("Buscar valor oficial", text: $taxonomyQuery)
            if isTaxonomyLoading { ProgressView("Cargando taxonomía…") }
            if let taxonomyError { Text(taxonomyError).stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            if !taxonomy.isEmpty {
                List {
                    ForEach(taxonomyOptions) { option in
                        Button { addTaxonomy(option) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                Text(option.id).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .contain)
                        .listRowBackground(palette.surface)
                    }
                }
                .frame(height: 180).listStyle(.plain).scrollContentBackground(.hidden)
                Text("Hasta 100 coincidencias. Puedes escribir cualquier valor que acepte el proveedor.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
        }
    }

    @ViewBuilder private var civitaiFilters: some View {
        ModelCatalogFormSection("Tipo y modelo base") {
            ModelCatalogField("Tipos (Checkpoint, LORA, VAE…)", text: $filters.types)
            ModelCatalogField("Modelos base (SDXL 1.0, Pony…)", text: $filters.baseModels)
            ModelCatalogField("Etiqueta", text: $filters.tags)
            DisclosureGroup("Más filtros del catálogo") {
                ModelCatalogField("Subtipo de checkpoint", text: $filters.checkpointType)
                ModelCatalogField("Formatos de archivo", text: $filters.fileFormats)
                ModelCatalogField("IDs de modelos", text: $filters.modelIDs)
                ModelCatalogField("IDs de versiones", text: $filters.versionIDs)
                ModelCatalogField("Estado de publicación", text: $filters.status)
                ModelCatalogField("Disponibilidad", text: $filters.availability)
                ModelCatalogPicker("Modo del periodo", selection: $filters.periodMode) {
                    Text("Predeterminado").tag(""); Text("Fecha de publicación").tag("published"); Text("Estadísticas").tag("stats")
                }
                ForEach(Self.flagLabels, id: \.0) { entry in
                    ModelCatalogPicker(entry.1, selection: flag(entry.0)) {
                        Text("Cualquiera").tag(""); Text("Sí").tag("true"); Text("No").tag("false")
                    }
                    .disabled(["favorites", "hidden", "followed"].contains(entry.0) && !connected)
                }
                if !connected { Text("Favoritos, ocultos y creadores seguidos necesitan conectar tu cuenta.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            }
        }
        ModelCatalogFormSection("Contenido para adultos") {
            ModelCatalogPicker("Origen de Civitai", selection: $filters.civitaiSite) { ForEach(ModelCatalogCivitaiSite.allCases, id: \.self) { Text($0.title).tag($0) } }
            ModelCatalogPicker("Contenido", selection: $filters.adultFilter) { ForEach(ModelCatalogAdultFilter.allCases, id: \.self) { Text($0.title).tag($0) } }
            Text("Excluir NSFW muestra contenido PG y PG-13. Todo incluye también contenido para adultos; Solo NSFW muestra únicamente contenido para adultos. El contenido bloqueado queda excluido. El acceso depende de los permisos, ajustes y restricciones regionales de tu cuenta de Civitai.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            if let url = provider.tokenSettingsURL { Link("Revisar los ajustes de mi cuenta de Civitai", destination: url).foregroundStyle(palette.readableAccent(on: palette.surface)) }
        }
        ModelCatalogFormSection("Permisos de uso comercial del catálogo") {
            ModelCatalogPicker("Uso comercial", selection: $filters.commercialUse) {
                Text("Cualquiera").tag(""); Text("Sin uso comercial").tag("None")
                Text("Imágenes").tag("Image"); Text("Generación en Civitai").tag("RentCivit")
                Text("Servicio de generación").tag("Rent"); Text("Venta del modelo").tag("Sell")
                Text("Venta de fusiones").tag("SellMerge")
            }
        }
        ModelCatalogFormSection("Otros permisos: filtrar esta página") {
            Toggle("Permite uso sin atribución", isOn: $filters.requireCreditOptional)
            Toggle("Permite obras derivadas", isOn: $filters.requireDerivatives)
            Toggle("Permite licencias diferentes", isOn: $filters.requireDifferentLicenses)
            Text("Estos permisos se comprueban en los resultados cargados. Pulsa «Cargar más» o continúa por las páginas para encontrar más modelos que los cumplan. Revisa la licencia de cada versión antes de usarla.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
        }
    }

    private static let flagLabels: [(String, String)] = [
        ("favorites", "Mis favoritos en Civitai"), ("hidden", "Ocultos de mi cuenta"),
        ("followed", "Creadores que sigo"), ("primaryFileOnly", "Solo archivo principal"),
        ("supportsGeneration", "Disponible para generación"), ("needsReview", "Necesita revisión"),
        ("earlyAccess", "Acceso anticipado"), ("paidAccess", "Acceso de pago"),
        ("hidePaid", "Ocultar acceso de pago"), ("onSale", "En oferta"),
        ("fromPlatform", "Desde la plataforma"), ("newCreators", "Creadores nuevos"), ("archived", "Archivados")
    ]

    private func flag(_ name: String) -> Binding<String> {
        Binding(get: { filters.flags[name] ?? "" }, set: { filters.flags[name] = $0.isEmpty ? nil : $0 })
    }

    private var taxonomyOptions: [ModelCatalogTaxonomy] {
        Array(taxonomy.lazy.filter { $0.kind == taxonomyKind && (taxonomyQuery.isEmpty || $0.label.localizedCaseInsensitiveContains(taxonomyQuery) || $0.id.localizedCaseInsensitiveContains(taxonomyQuery)) }.prefix(100))
    }

    private func addTaxonomy(_ option: ModelCatalogTaxonomy) {
        func append(_ current: String, value: String) -> String { ModelCatalogFilters.terms(current + "," + value).joined(separator: ", ") }
        switch taxonomyKind {
        case "pipeline_tag": filters.task = option.id
        case "library": filters.library = append(filters.library, value: option.id)
        case "license": filters.license = append(filters.license, value: option.id)
        case "language": filters.language = append(filters.language, value: option.id)
        case "dataset": filters.datasets = append(filters.datasets, value: option.id)
        default: filters.tags = append(filters.tags, value: option.id)
        }
    }
}
