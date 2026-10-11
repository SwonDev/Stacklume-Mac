import Foundation

/// Aplica reglas de auto-clasificación a un enlace (equivale a `classification.ts`
/// del original). Muta el `Bookmark` directamente; el guardado lo hace el llamante.
@MainActor
public enum ClassificationEngine {

    public static func apply(
        to bookmark: Bookmark,
        rules: [ClassificationRule],
        categories: [BookmarkCategory],
        tags: [Tag]
    ) {
        for rule in rules.sorted(by: { $0.order < $1.order }) where rule.isActive {
            guard matches(rule, bookmark) else { continue }
            // Aplica TODAS las acciones de la regla (la primaria + las adicionales).
            for action in rule.allActions {
                apply(action: action, to: bookmark, categories: categories, tags: tags)
            }
        }
    }

    /// Aplica UNA acción al enlace (asignar categoría si no tiene, o añadir etiqueta si falta).
    static func apply(action: RuleActionSpec, to bookmark: Bookmark,
                      categories: [BookmarkCategory], tags: [Tag]) {
        guard let id = UUID(uuidString: action.value) else { return }
        switch action.type {
        case .setCategory:
            if bookmark.category == nil, let category = categories.first(where: { $0.id == id }) {
                bookmark.category = category
            }
        case .addTag:
            if let tag = tags.first(where: { $0.id == id }),
               !bookmark.tags.contains(where: { $0.id == id }) {
                bookmark.tags.append(tag)
            }
        }
    }

    public static func matches(_ rule: ClassificationRule, _ bookmark: Bookmark) -> Bool {
        // Todas las condiciones con valor (la primaria + las adicionales), combinadas según
        // el modo: `.all` = AND (todas), `.any` = OR (alguna). Una sola condición = igual que antes.
        let conditions = rule.allConditions.filter {
            !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !conditions.isEmpty else { return false }
        switch rule.matchMode {
        case .all: return conditions.allSatisfy { matches(condition: $0, bookmark) }
        case .any: return conditions.contains { matches(condition: $0, bookmark) }
        }
    }

    /// Evalúa UNA condición sobre el enlace.
    public static func matches(condition: RuleConditionSpec, _ bookmark: Bookmark) -> Bool {
        let needle = condition.value.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        switch condition.type {
        case .urlPattern:
            return bookmark.url.lowercased().contains(needle)
        case .titleKeyword:
            return bookmark.title.lowercased().contains(needle)
        case .platform:
            return bookmark.platform.rawValue.lowercased() == needle
        case .domain:
            return host(of: bookmark.url).contains(needle)
        }
    }

    private static func host(of urlString: String) -> String {
        let value = urlString.contains("://") ? urlString : "https://" + urlString
        let host = URL(string: value)?.host()?.lowercased() ?? urlString.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
