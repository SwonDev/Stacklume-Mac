import Foundation
import SwiftData

/// Pegatina colocada sobre el lienzo del dashboard.
@Model
public final class PlacedSticker {
    public var id: UUID = UUID()
    /// Símbolo: nombre de SF Symbol o emoji.
    public var symbol: String = "star.fill"
    /// `true` si `symbol` es un SF Symbol; `false` si es un emoji/texto.
    public var isSFSymbol: Bool = true
    public var colorHex: String = "#D4A853"

    /// Widget al que está anclada la pegatina. `x`/`y` son relativas a ESE widget
    /// (no a la pantalla), de modo que la pegatina se desplaza y hace scroll junto
    /// al widget. `nil` solo para pegatinas heredadas sin anclar (se migran).
    public var widgetID: UUID?

    /// Posición normalizada (0...1) relativa al widget anclado.
    public var x: Double = 0.5
    public var y: Double = 0.5
    public var scale: Double = 1.0
    public var rotation: Double = 0      // grados
    public var zIndex: Int = 0

    public var createdAt: Date = Date()

    public init(
        id: UUID = UUID(),
        symbol: String = "star.fill",
        isSFSymbol: Bool = true,
        colorHex: String = "#D4A853",
        widgetID: UUID? = nil,
        x: Double = 0.5,
        y: Double = 0.5,
        scale: Double = 1.0,
        rotation: Double = 0,
        zIndex: Int = 0
    ) {
        self.id = id
        self.symbol = symbol
        self.isSFSymbol = isSFSymbol
        self.colorHex = colorHex
        self.widgetID = widgetID
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
        self.zIndex = zIndex
        self.createdAt = Date()
    }
}
