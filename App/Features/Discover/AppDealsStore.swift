import Foundation
import SwiftData
import StacklumeCore
import StacklumeMetadata

/// Rastreador de precios de la App Store (apps/juegos de PAGO). Usa solo la API
/// oficial de Apple (iTunes Lookup + RSS top-paid) y guarda el historial en
/// SwiftData (`TrackedApp`) para detectar bajadas comparando precios. App
/// Store-safe: no hay servicio externo de ofertas. Port directo del iPhone
/// (Foundation + SwiftData puros, sin UIKit) — reutiliza `iTunesPriceService` del
/// paquete compartido `StacklumeMetadata`.
@MainActor
enum AppDealsStore {
    private static var isSyncing = false
    /// No refrescar precios más a menudo que esto (salvo `force`).
    private static let refreshInterval: TimeInterval = 60 * 60 * 6   // 6 h

    /// Código de tienda del usuario (es, us…) para que los precios sean los suyos.
    private static var country: String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    /// Siembra (primer uso) o refresca los precios y detecta bajadas.
    static func sync(context: ModelContext, force: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let tracked = (try? context.fetch(FetchDescriptor<TrackedApp>())) ?? []

        if tracked.isEmpty {
            await seed(context: context)
            return
        }
        // Si se vigilan apps pero ningún juego (versión anterior sin juegos),
        // añade los juegos de pago al instante, sin esperar al refresco.
        if !tracked.contains(where: \.isGame) {
            await mergeNew(into: tracked, context: context)
        }
        let lastCheck = tracked.map(\.lastCheckedAt).max() ?? .distantPast
        guard force || Date().timeIntervalSince(lastCheck) >= refreshInterval else { return }
        await refresh(existing: tracked, context: context)
    }

    /// Añade al seguimiento las top-paid (apps y juegos) que aún no se vigilan.
    private static func mergeNew(into existing: [TrackedApp], context: ModelContext) async {
        let cc = country
        let knownIDs = Set(existing.map(\.trackId))
        let ids = await seedIDs(country: cc).filter { !knownIDs.contains($0) }
        guard !ids.isEmpty else { return }
        let apps = await iTunesPriceService.shared.lookup(ids: ids, country: cc)
        for app in apps where app.price > 0 {
            context.insert(makeTracked(from: app))
        }
        context.saveLogging()
    }

    /// Conjunto de IDs a vigilar: top-paid general (apps) + top-paid de juegos.
    private static func seedIDs(country cc: String) async -> [Int] {
        async let apps = iTunesPriceService.shared.topPaidIDs(country: cc, limit: 100)
        async let games = iTunesPriceService.shared.topPaidGameIDs(country: cc, limit: 100)
        let combined = await apps + games
        return Array(Set(combined))   // sin duplicados
    }

    /// Crea la línea base con las apps y juegos de pago más populares.
    private static func seed(context: ModelContext) async {
        let cc = country
        let ids = await seedIDs(country: cc)
        let apps = await iTunesPriceService.shared.lookup(ids: ids, country: cc)
        for app in apps where app.price > 0 {   // solo productos de pago (pago único)
            context.insert(makeTracked(from: app))
        }
        context.saveLogging()
    }

    /// Refresca los precios vigilados, detecta bajadas y añade nuevas top-paid.
    private static func refresh(existing: [TrackedApp], context: ModelContext) async {
        let cc = country
        let now = Date()

        // 1) Refrescar los vigilados y detectar bajadas.
        let ids = existing.map(\.trackId)
        let apps = await iTunesPriceService.shared.lookup(ids: ids, country: cc)
        let byId = Dictionary(apps.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
        for app in existing {
            guard let fresh = byId[app.trackId] else { continue }
            let newPrice = fresh.price
            if newPrice > app.highestPrice { app.highestPrice = newPrice }
            if newPrice < app.currentPrice {
                app.previousPrice = app.currentPrice
                app.priceDropAt = now
            }
            app.currentPrice = newPrice
            app.currency = fresh.currency
            app.lastCheckedAt = now
        }

        // 2) Ampliar la cobertura con nuevas top-paid (apps y juegos) no vigiladas.
        let knownIDs = Set(existing.map(\.trackId))
        let topIDs = await seedIDs(country: cc)
        let newIDs = topIDs.filter { !knownIDs.contains($0) }
        if !newIDs.isEmpty {
            let newApps = await iTunesPriceService.shared.lookup(ids: newIDs, country: cc)
            for app in newApps where app.price > 0 {
                context.insert(makeTracked(from: app))
            }
        }
        context.saveLogging()
    }

    /// Añade una app concreta al seguimiento (búsqueda manual). Devuelve false si
    /// es gratis (no es producto de pago) o ya está vigilada.
    @discardableResult
    static func track(_ app: AppStoreApp, context: ModelContext) -> Bool {
        guard app.price > 0 else { return false }
        let id = app.trackId
        let existing = try? context.fetch(
            FetchDescriptor<TrackedApp>(predicate: #Predicate { $0.trackId == id }))
        guard (existing?.isEmpty ?? true) else { return false }
        context.insert(makeTracked(from: app))
        context.saveLogging()
        return true
    }

    private static func makeTracked(from app: AppStoreApp) -> TrackedApp {
        TrackedApp(
            trackId: app.trackId, name: app.name, artist: app.artist,
            genre: app.genre, artworkURL: app.artworkURL, appStoreURL: app.url,
            currency: app.currency, isGame: app.isGame, currentPrice: app.price)
    }
}
