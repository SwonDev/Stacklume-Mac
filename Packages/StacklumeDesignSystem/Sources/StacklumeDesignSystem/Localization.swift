import Foundation

/// Localiza los nombres de tema usando el catálogo del propio paquete. El español
/// es el idioma base; los nombres propios (Tokyo Night, Catppuccin…) no tienen
/// traducción y caen a su valor original.
@inline(__always)
func localizedToken(_ value: String) -> String {
    String(localized: String.LocalizationValue(value), bundle: .module)
}
