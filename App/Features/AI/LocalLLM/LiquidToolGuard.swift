import Foundation

// Salvaguardas del bucle de tool calling del agente, extraídas de `LiquidConversation`
// para acotar su tamaño. Tipos independientes (sin estado del chat): movimiento puro,
// comportamiento idéntico. Antes `private` en LiquidConversation; ahora internos al módulo.

/// Error interno para cortar el bucle de tool calling cuando se excede el presupuesto
/// de acciones (evita bucles infinitos del modelo).
enum LiquidLoopError: Error { case aborted }

/// Limita y vigila las llamadas a herramientas de una respuesta para impedir bucles
/// infinitos: cuenta total de llamadas (límite blando/duro) y detecta llamadas idénticas
/// repetidas. Es un actor → Sendable y seguro de capturar en el `toolDispatch` (`@Sendable`).
actor ToolGuard {
    enum Decision { case proceed, repeated, stopSoft, abort }
    private let soft: Int
    private let hard: Int
    private var count = 0
    private var seen: [String: Int] = [:]
    /// Último resultado por firma, para devolverlo (idempotente) si se repite la llamada
    /// en vez de un regaño que el modelo pueda confundir con la respuesta.
    private var lastResults: [String: String] = [:]

    init(soft: Int, hard: Int) { self.soft = soft; self.hard = hard }

    func check(_ signature: String) -> Decision {
        count += 1
        if count > hard { return .abort }
        let n = (seen[signature] ?? 0) + 1
        seen[signature] = n
        if n > 1 { return .repeated }   // bloquea la 2ª llamada idéntica (evita repeticiones)
        if count > soft { return .stopSoft }
        return .proceed
    }

    func store(_ signature: String, _ result: String) { lastResults[signature] = result }
    func lastResult(_ signature: String) -> String? { lastResults[signature] }
}
