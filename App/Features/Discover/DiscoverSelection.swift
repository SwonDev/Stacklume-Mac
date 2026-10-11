import SwiftUI

/// Ítem de descubrimiento unificado: lo que se muestra en el panel de DETALLE (derecha)
/// al hacer clic en una fila de cualquier feed, y lo que se guarda en la biblioteca.
/// Se construye al vuelo desde la fila (URL/título/imagen) + la fuente del feed; la
/// descripción larga la obtiene el panel de detalle bajo demanda (metadatos OG).
struct DiscoverItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    var imageURL: String?
    var sourceName: String
    var sourceIcon: String
}

/// Selección actual de un ítem de descubrimiento. La columna de detalle la observa para
/// mostrar `DiscoverItemDetailView`. Inyectada en el entorno por `RootWindowView`.
@MainActor
@Observable
final class DiscoverSelection {
    var selected: DiscoverItem?
}

/// Fuente (feed) activa, inyectada por cada tarjeta-sección de «Descubrir» para que sus
/// filas sepan de qué feed provienen al construir el `DiscoverItem` (nombre + icono).
struct DiscoverSource: Equatable {
    let name: String
    let icon: String
}

private struct DiscoverSourceKey: EnvironmentKey {
    static let defaultValue: DiscoverSource? = nil
}

extension EnvironmentValues {
    var discoverSource: DiscoverSource? {
        get { self[DiscoverSourceKey.self] }
        set { self[DiscoverSourceKey.self] = newValue }
    }
}
