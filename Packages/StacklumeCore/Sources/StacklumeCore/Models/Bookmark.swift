import Foundation
import SwiftData

/// Marcador (bookmark). Modelo central de Stacklume.
///
/// Incluye todos los campos del original; los de adquisición automática de
/// metadatos se rellenan en la Fase 2 y los de IA en la Fase 3.
@Model
public final class Bookmark {
    // Índices para que las consultas/ordenaciones escalen con miles de enlaces
    // (orden por fecha, orden manual y filtrado por estado a nivel de base de datos).
    #Index<Bookmark>([\.createdAt], [\.order], [\.deletedAt], [\.isFavorite], [\.isArchived])

    public var id: UUID = UUID()

    // Datos básicos
    public var url: String = ""
    public var title: String = ""
    /// Descripción (`description` está reservado por `CustomStringConvertible`).
    public var details: String?
    public var imageURL: String?
    public var faviconURL: String?

    // Organización
    public var isFavorite: Bool = false
    public var order: Int = 0
    /// Color de destacado (hex) para resaltar visualmente el enlace dentro de su
    /// categoría y encontrarlo más rápido. `nil` = sin destacar. Migración ligera.
    public var highlightColorHex: String?

    // Metadatos de página (Fase 2)
    public var siteName: String?
    public var author: String?
    public var publishedAt: Date?

    // Detección de plataforma (Fase 2)
    public var platform: Platform = Platform.generic
    public var contentType: ContentType = ContentType.website
    public var platformColor: String?
    public var source: String?

    // Salud (Fase 2)
    public var lastCheckedAt: Date?
    public var healthStatus: HealthStatus?

    // Lectura personal
    public var isRead: Bool = false
    public var notes: String?
    public var reminderAt: Date?
    public var readingStatus: ReadingStatus = ReadingStatus.inbox
    public var reviewAt: Date?

    // IA (Fase 3)
    public var installCommands: [String] = []
    public var summary: String?
    public var semanticTags: [String] = []

    /// Datos enriquecidos específicos de la plataforma (p. ej. estrellas y forks
    /// de un repositorio de GitHub). Opcional → migración ligera retrocompatible.
    public var repoInfo: RepoInfo?

    /// Comando de instalación guardado (npm i…, pnpm add…, pip install…). Si está
    /// presente, el enlace es un "comando" y se muestra con una tarjeta de código
    /// copiable. Opcional → migración ligera retrocompatible.
    public var command: String?

    /// Archivado: guardado pero fuera de la vista principal (no es papelera).
    public var isArchived: Bool = false

    /// Archivo adjunto guardado localmente (foto/PDF) cuando el marcador ES un
    /// archivo en vez de una URL. `fileKind` indica el tipo ("image"/"pdf").
    @Attribute(.externalStorage) public var fileData: Data?
    public var fileKind: String?

    /// Copia legible offline del artículo (HTML simplificado) para leer sin conexión.
    @Attribute(.externalStorage) public var offlineHTML: String?

    /// Texto plano del contenido offline, SOLO para la búsqueda de texto completo
    /// (carga diferida; se rellena al guardar la copia y por backfill de las antiguas).
    /// Separado del HTML para no cargar el documento entero al buscar. Migración ligera.
    @Attribute(.externalStorage) public var offlineText: String?

    // Auditoría
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    /// Borrado lógico (soft delete).
    public var deletedAt: Date?

    // Relaciones
    public var category: BookmarkCategory?
    @Relationship(inverse: \Tag.links)
    public var tags: [Tag] = []
    /// Resaltados / anotaciones del enlace (se borran al borrar el marcador).
    @Relationship(deleteRule: .cascade, inverse: \Highlight.bookmark)
    public var highlights: [Highlight] = []

    public init(
        id: UUID = UUID(),
        url: String = "",
        title: String = "",
        details: String? = nil,
        category: BookmarkCategory? = nil,
        tags: [Tag] = [],
        isFavorite: Bool = false,
        notes: String? = nil,
        readingStatus: ReadingStatus = .inbox,
        platform: Platform = .generic,
        contentType: ContentType = .website,
        order: Int = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.details = details
        self.category = category
        self.tags = tags
        self.isFavorite = isFavorite
        self.notes = notes
        self.readingStatus = readingStatus
        self.platform = platform
        self.contentType = contentType
        self.order = order
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// `true` si el enlace no está borrado lógicamente.
    public var isActive: Bool { deletedAt == nil }
}
