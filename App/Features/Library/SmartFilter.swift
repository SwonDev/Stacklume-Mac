import Foundation
import StacklumePersistence

/// Filtros inteligentes de la Biblioteca (paridad con el iPhone, estilo Raindrop).
///
/// Réplica EXACTA de los casos del iPhone (`Features/Library/LibraryView.swift`).
/// Cada caso traduce a una bandera de `LinkFilter` (la lógica de filtrado vive en
/// el paquete compartido `StacklumePersistence/LinkFiltering.swift`, que ya soporta
/// todas estas banderas). Aquí solo describimos los casos y su presentación.
enum SmartFilter: String, CaseIterable, Identifiable, Hashable {
    case unread, broken, untagged, uncategorized, reminders, archived

    var id: String { rawValue }

    /// Etiqueta visible (mismos textos que el iPhone).
    var title: String {
        switch self {
        case .unread: "Sin leer"
        case .broken: "Enlaces rotos"
        case .untagged: "Sin etiqueta"
        case .uncategorized: "Sin categoría"
        case .reminders: "Con recordatorio"
        case .archived: "Archivados"
        }
    }

    /// Icono SF Symbol (mismos que el iPhone).
    var icon: String {
        switch self {
        case .unread: "circle.badge.exclamationmark"
        case .broken: "exclamationmark.triangle"
        case .untagged: "tag.slash"
        case .uncategorized: "folder.badge.questionmark"
        case .reminders: "bell"
        case .archived: "archivebox"
        }
    }

    /// Aplica este filtro inteligente sobre un `LinkFilter`, igual que el iPhone.
    func apply(to filter: inout LinkFilter) {
        switch self {
        case .unread: filter.onlyUnread = true
        case .broken: filter.onlyBroken = true
        case .untagged: filter.onlyUntagged = true
        case .uncategorized: filter.onlyUncategorized = true
        case .reminders: filter.onlyWithReminder = true
        case .archived: filter.onlyArchived = true
        }
    }
}
