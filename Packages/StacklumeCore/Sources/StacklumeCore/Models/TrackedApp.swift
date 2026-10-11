import Foundation
import SwiftData

/// App o juego de pago de la App Store cuyo precio se vigila para detectar
/// bajadas. Se rellena con la API oficial de Apple (iTunes Lookup) y se compara
/// el precio en cada actualización para detectar ofertas. Solo se vigilan
/// productos de pago (price > 0), es decir, de pago único de descarga.
@Model
public final class TrackedApp {
    /// Identificador de la app en la App Store (trackId de iTunes). Único.
    @Attribute(.unique) public var trackId: Int = 0

    public var name: String = ""
    public var artist: String = ""
    public var genre: String = ""
    public var artworkURL: String?
    public var appStoreURL: String = ""
    public var currency: String = "USD"

    /// `true` si es un juego (para prefiltrar juegos vs apps).
    public var isGame: Bool = false

    /// Precio actual (en la última comprobación).
    public var currentPrice: Double = 0
    /// Precio anterior conocido (antes de la última bajada). `nil` si nunca bajó.
    public var previousPrice: Double?
    /// Precio más alto observado (referencia para el % de descuento).
    public var highestPrice: Double = 0

    public var firstSeenAt: Date = Date()
    public var lastCheckedAt: Date = Date()
    /// Fecha de la última bajada de precio detectada. `nil` si nunca ha bajado.
    public var priceDropAt: Date?

    public init(
        trackId: Int,
        name: String,
        artist: String,
        genre: String,
        artworkURL: String?,
        appStoreURL: String,
        currency: String,
        isGame: Bool,
        currentPrice: Double
    ) {
        self.trackId = trackId
        self.name = name
        self.artist = artist
        self.genre = genre
        self.artworkURL = artworkURL
        self.appStoreURL = appStoreURL
        self.currency = currency
        self.isGame = isGame
        self.currentPrice = currentPrice
        self.previousPrice = nil
        self.highestPrice = currentPrice
        self.firstSeenAt = Date()
        self.lastCheckedAt = Date()
        self.priceDropAt = nil
    }

    /// `true` si el precio bajó respecto al máximo observado y sigue de pago.
    public var isOnSale: Bool {
        currentPrice > 0 && highestPrice > currentPrice
    }

    /// Porcentaje de descuento respecto al precio más alto observado (0–100).
    public var discountPercent: Int {
        guard highestPrice > 0, currentPrice < highestPrice else { return 0 }
        return Int(((highestPrice - currentPrice) / highestPrice * 100).rounded())
    }

    public func priceText(_ value: Double) -> String {
        String(format: "%.2f %@", value, currency)
    }
    public var currentPriceText: String { priceText(currentPrice) }
    public var highestPriceText: String { priceText(highestPrice) }
}
