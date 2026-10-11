import SwiftUI

/// Política local del ensayo; nil conserva exactamente los valores públicos de macOS.
struct NativeUIQAAccessibility: Sendable, Equatable {
    var reduceMotion: Bool?
    var reduceTransparency: Bool?
    var increasedContrast: Bool?

    func motion(system: Bool) -> Bool { reduceMotion ?? system }
    func transparency(system: Bool) -> Bool { reduceTransparency ?? system }
    func contrast(system: ColorSchemeContrast) -> ColorSchemeContrast {
        increasedContrast.map { $0 ? .increased : .standard } ?? system
    }
}

extension EnvironmentValues {
    @Entry var nativeUIQAAccessibility: NativeUIQAAccessibility? = nil
}
