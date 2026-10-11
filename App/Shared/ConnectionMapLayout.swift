import Foundation

/// Punto normalizado (0…1) independiente de SwiftUI. Mantener la geometría en
/// Foundation permite probar el mapa sin compilar la aplicación ni sus paquetes de IA.
struct ConnectionMapPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// Geometría determinista del explorador de conexiones.
///
/// La vista mantiene una constelación pequeña y editorial: como máximo cuatro satélites
/// visibles. El resto se descubre progresivamente desde el inspector, evitando convertir
/// la biblioteca en un diagrama técnico saturado.
enum ConnectionMapLayout {
    static let maximumVisibleSatellites = 4
    static let center = ConnectionMapPoint(x: 0.5, y: 0.43)

    static func satellitePoints(count: Int, compact: Bool) -> [ConnectionMapPoint] {
        let safeCount = min(max(count, 0), maximumVisibleSatellites)
        guard safeCount > 0 else { return [] }

        let sideX = compact ? 0.22 : 0.17
        let oppositeX = 1 - sideX
        let upperY = compact ? 0.19 : 0.21
        let lowerY = compact ? 0.67 : 0.65

        switch safeCount {
        case 1:
            return [ConnectionMapPoint(x: 0.5, y: upperY)]
        case 2:
            return [
                ConnectionMapPoint(x: sideX, y: 0.34),
                ConnectionMapPoint(x: oppositeX, y: 0.34),
            ]
        case 3:
            return [
                ConnectionMapPoint(x: sideX, y: upperY),
                ConnectionMapPoint(x: oppositeX, y: upperY),
                ConnectionMapPoint(x: 0.5, y: lowerY),
            ]
        default:
            return [
                ConnectionMapPoint(x: sideX, y: upperY),
                ConnectionMapPoint(x: oppositeX, y: upperY),
                ConnectionMapPoint(x: sideX, y: lowerY),
                ConnectionMapPoint(x: oppositeX, y: lowerY),
            ]
        }
    }

    /// Convierte una puntuación abierta del motor híbrido en intensidad visual estable.
    static func normalizedStrength(score: Double) -> Double {
        min(max(score / 2.0, 0.22), 1.0)
    }
}
