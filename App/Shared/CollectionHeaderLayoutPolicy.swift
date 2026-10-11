import Foundation

/// Decide cuándo la identidad y los controles de la cabecera necesitan dos filas.
///
/// Se mantiene separada del `Layout` de SwiftUI para que la frontera responsive sea
/// determinista y pueda probarse sin compilar la app ni sus dependencias de IA.
enum CollectionHeaderLayoutPolicy {
    static func shouldStack(
        availableWidth: CGFloat,
        identityIdealWidth: CGFloat,
        controlsIdealWidth: CGFloat,
        spacing: CGFloat
    ) -> Bool {
        // El texto se trunca; la llegada de resultados no cambia la geometría.
        let requiredWidth: CGFloat = 180
            + max(0, controlsIdealWidth)
            + max(0, spacing)
        return max(0, availableWidth) < requiredWidth
    }
}
