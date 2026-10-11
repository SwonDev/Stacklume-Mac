import WidgetKit

/// Pide a WidgetKit que recargue los widgets cuando cambian los datos relevantes
/// (favoritos, recientes, cola de lectura, categorías), para que la pantalla de
/// inicio y la de bloqueo reflejen los cambios al instante.
enum WidgetReloader {
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
