import Foundation

/// Localiza una cadena de dominio (nombres de enums, etc.) usando el catálogo de
/// cadenas del propio paquete (`Bundle.module`). El español es el idioma base, de
/// modo que cualquier cadena sin traducir cae a su valor en español.
@inline(__always)
func localizedDomain(_ value: String) -> String {
    String(localized: String.LocalizationValue(value), bundle: .module)
}
