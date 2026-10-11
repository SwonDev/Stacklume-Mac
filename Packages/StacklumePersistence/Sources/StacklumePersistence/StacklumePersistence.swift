import Foundation
import StacklumeCore

/// Punto de entrada de la capa de persistencia.
/// La configuración del `ModelContainer`, los repositorios `@ModelActor` y la
/// búsqueda con `#Predicate` se añaden a continuación en la Fase 1.
public enum StacklumePersistence {
    public static let storeName = "Stacklume"
}
