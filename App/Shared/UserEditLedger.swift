import Foundation

/// Marca PERSISTENTE de los campos que el USUARIO editó a mano (título y/o descripción), para que
/// el enriquecido automático (IA, red, traducción) NUNCA los pise. El usuario pidió (2026-06-28)
/// que sus ediciones manuales se respeten y se señalen con una marca visual MUY sutil.
///
/// Side-store en `UserDefaults` indexado por UUID, igual que [[EnrichmentLedger]] (el `@Model`
/// `Bookmark` vive en el paquete compartido read-only y no se le puede añadir un flag). Mismo
/// patrón que `HighlightNoteStore`/`ReadingProgressStore` (ver «almacenamiento-lateral-modelo-readonly»).
///
/// El enriquecido automático y el barrido «a fondo» RESPETAN estas marcas. Solo «Mejorar con IA»
/// sobre UN enlace concreto las limpia (`clear`): ahí el usuario pide explícitamente regenerar ese.
@MainActor
enum UserEditLedger {
    private static let titleKey = "stacklume.userEdited.title"
    private static let detailsKey = "stacklume.userEdited.details"

    private static var titleSet: Set<String> = load(titleKey)
    private static var detailsSet: Set<String> = load(detailsKey)

    private static func load(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    private static func persist(_ set: Set<String>, _ key: String) {
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    /// ¿El usuario editó a mano el TÍTULO de este enlace? El enriquecido no debe tocarlo.
    static func isTitleEdited(_ id: UUID) -> Bool { titleSet.contains(id.uuidString) }
    /// ¿El usuario editó a mano la DESCRIPCIÓN de este enlace? El enriquecido no debe tocarla.
    static func isDetailsEdited(_ id: UUID) -> Bool { detailsSet.contains(id.uuidString) }
    /// ¿Algún campo de texto fue editado a mano? (lo usa la marca visual sutil de la fila/ficha).
    static func isEdited(_ id: UUID) -> Bool { isTitleEdited(id) || isDetailsEdited(id) }

    static func markTitleEdited(_ id: UUID) {
        if titleSet.insert(id.uuidString).inserted { persist(titleSet, titleKey) }
    }
    static func markDetailsEdited(_ id: UUID) {
        if detailsSet.insert(id.uuidString).inserted { persist(detailsSet, detailsKey) }
    }

    /// Quita las marcas de un enlace: lo invoca «Mejorar con IA» sobre ESE enlace (el usuario pide
    /// regenerarlo a propósito), de modo que la protección no impida la regeneración solicitada.
    static func clear(_ id: UUID) {
        if titleSet.remove(id.uuidString) != nil { persist(titleSet, titleKey) }
        if detailsSet.remove(id.uuidString) != nil { persist(detailsSet, detailsKey) }
    }


    /// Elimina las marcas de varios enlaces con una sola escritura por conjunto.
    static func remove(_ ids: [UUID]) {
        let removed = Set(ids.map(\.uuidString))
        guard !removed.isEmpty else { return }
        let titles = titleSet.subtracting(removed)
        if titles.count != titleSet.count { titleSet = titles; persist(titleSet, titleKey) }
        let details = detailsSet.subtracting(removed)
        if details.count != detailsSet.count { detailsSet = details; persist(detailsSet, detailsKey) }
    }

    /// Restablecimiento total, incluida la caché estática en memoria.
    static func removeAll() {
        titleSet = []; detailsSet = []
        UserDefaults.standard.removeObject(forKey: titleKey)
        UserDefaults.standard.removeObject(forKey: detailsKey)
    }
}
