import WidgetKit
import SwiftUI

// MARK: - Colores del tema

/// Fondo navy oscuro: #01030b
private let navyBackground = Color(red: 0.004, green: 0.012, blue: 0.043)

/// Acento dorado: #d6a62e
private let goldAccent = Color(red: 0.839, green: 0.651, blue: 0.180)

private let textPrimary = Color.white
private let textSecondary = Color.white.opacity(0.55)

// MARK: - Parseo de hex (sin dependencias externas)

private func colorFromHex(_ hex: String) -> Color {
    var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.hasPrefix("#") { clean = String(clean.dropFirst()) }
    guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
        return goldAccent
    }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8)  & 0xFF) / 255.0
    let b = Double(value         & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

// MARK: - Timeline entry

struct FavoritesEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshot.Item]
}

// MARK: - Timeline provider

struct FavoritesProvider: TimelineProvider {
    func placeholder(in context: Context) -> FavoritesEntry {
        let samples = [
            WidgetSnapshot.Item(id: "1", title: "Documentación de SwiftUI", host: "developer.apple.com", colorHex: "#F05138"),
            WidgetSnapshot.Item(id: "2", title: "GitHub", host: "github.com", colorHex: "#24292f"),
            WidgetSnapshot.Item(id: "3", title: "Dribbble", host: "dribbble.com", colorHex: "#EA4C89")
        ]
        return FavoritesEntry(date: Date(), items: samples)
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoritesEntry) -> Void) {
        let snap = WidgetSnapshot.load()
        completion(FavoritesEntry(date: snap.generatedAt, items: snap.favorites))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoritesEntry>) -> Void) {
        let snap = WidgetSnapshot.load()
        let entry = FavoritesEntry(date: snap.generatedAt, items: snap.favorites)
        // Refresco cada 30 minutos
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }
}

// MARK: - Vistas

struct FavoritesWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FavoritesEntry

    private var maxRows: Int {
        switch family {
        case .systemSmall: return 3
        default: return 6
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Cabecera
            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(goldAccent)
                Text("Favoritos")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Text("Stacklume")
                    .font(.caption2)
                    .foregroundStyle(textSecondary)
            }

            if entry.items.isEmpty {
                Spacer()
                Text("Marca favoritos en Stacklume para verlos aquí.")
                    .font(.caption2)
                    .foregroundStyle(textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                ForEach(entry.items.prefix(maxRows)) { item in
                    itemRow(item)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(navyBackground, for: .widget)
        .widgetURL(URL(string: "stacklume://open"))
    }

    private func itemRow(_ item: WidgetSnapshot.Item) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colorFromHex(item.colorHex))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                if family != .systemSmall {
                    Text(item.host)
                        .font(.system(size: 9))
                        .foregroundStyle(textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Widget principal

struct FavoritesWidget: Widget {
    let kind = "StacklumeFavoritesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FavoritesProvider()) { entry in
            FavoritesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Favoritos de Stacklume")
        .description("Tus enlaces favoritos siempre a mano.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
