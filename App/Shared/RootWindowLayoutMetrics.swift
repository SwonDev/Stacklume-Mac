import Foundation

/// Contrato único de anchuras para la ventana principal.
///
/// El mínimo global usa el máximo permitido del sidebar, no su mínimo. AppKit
/// restaura el ancho anterior de cada divisor y, si la ventana no puede contenerlo,
/// desplaza el primer panel fuera del borde izquierdo en vez de reducirlo.
enum RootWindowLayoutMetrics {
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 230
    static let sidebarMaximumWidth: CGFloat = 320

    static let libraryMinimumWidth: CGFloat = 360
    static let libraryIdealWidth: CGFloat = 460
    static let libraryMaximumWidth: CGFloat = 720

    static let detailMinimumWidth: CGFloat = 480
    static let detailIdealWidth: CGFloat = 760

    /// Dos divisores, los insets del rail y un pequeño margen contra redondeos de AppKit.
    static let dividerAndInsetBudget: CGFloat = 20

    static let minimumWindowWidth = sidebarMaximumWidth
        + libraryMinimumWidth
        + detailMinimumWidth
        + dividerAndInsetBudget
}
