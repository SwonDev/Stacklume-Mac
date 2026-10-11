import Foundation

/// Preferencia lateral del Mac; el modelo compartido AppSettings permanece intacto.
enum StacklumeTextScale: Int, CaseIterable, Identifiable, Sendable {
    case standard = 100, medium = 125, large = 150, extraLarge = 175, maximum = 200
    static let storageKey = "stacklume.textScalePercent"
    var id: Int { rawValue }
    var title: String { "\(rawValue) %" }
    var factor: Double { Double(rawValue) / 100 }
    init(storedPercent: Int) { self = Self(rawValue: storedPercent) ?? .standard }
    static func normalizedFactor(_ factor: Double) -> Double {
        switch factor {
        case 1, 1.25, 1.5, 1.75, 2: factor
        default: 1
        }
    }
}
