import Testing
import Foundation
import StacklumeCore

// Reglas de auto-clasificación MULTI-CONDICIÓN: `ClassificationEngine.matches` combina la
// condición primaria + las adicionales según `matchMode` (TODAS = AND, ALGUNA = OR). Una
// sola condición se comporta igual que antes (retrocompatible).

@Suite("ClassificationEngine — reglas multi-condición")
@MainActor
struct ClassificationEngineTests {

    private func makeRule(_ first: RuleConditionSpec,
                          _ extra: [RuleConditionSpec] = [],
                          mode: RuleMatchMode = .all) -> ClassificationRule {
        let r = ClassificationRule(conditionType: first.type, conditionValue: first.value)
        r.matchMode = mode
        r.extraConditions = extra
        return r
    }

    @Test("AND: deben cumplirse TODAS las condiciones")
    func andMode() {
        let r = makeRule(RuleConditionSpec(type: .domain, value: "github"),
                         [RuleConditionSpec(type: .titleKeyword, value: "swift")], mode: .all)
        #expect(ClassificationEngine.matches(r, Bookmark(url: "https://github.com/apple/swift", title: "Swift")))
        #expect(!ClassificationEngine.matches(r, Bookmark(url: "https://github.com/jetbrains/kotlin", title: "Kotlin")))
        #expect(!ClassificationEngine.matches(r, Bookmark(url: "https://gitlab.com/x", title: "Swift")))
    }

    @Test("OR: basta con que se cumpla ALGUNA condición")
    func orMode() {
        let r = makeRule(RuleConditionSpec(type: .domain, value: "github"),
                         [RuleConditionSpec(type: .domain, value: "gitlab")], mode: .any)
        #expect(ClassificationEngine.matches(r, Bookmark(url: "https://gitlab.com/x", title: "X")))
        #expect(ClassificationEngine.matches(r, Bookmark(url: "https://github.com/x", title: "X")))
        #expect(!ClassificationEngine.matches(r, Bookmark(url: "https://example.com", title: "X")))
    }

    @Test("Una sola condición se comporta como antes (retrocompatible)")
    func singleCondition() {
        let r = makeRule(RuleConditionSpec(type: .domain, value: "github"))
        #expect(ClassificationEngine.matches(r, Bookmark(url: "https://github.com/x", title: "X")))
        #expect(!ClassificationEngine.matches(r, Bookmark(url: "https://example.com", title: "X")))
    }

    @Test("Las condiciones con valor vacío se ignoran")
    func ignoresEmpty() {
        let r = makeRule(RuleConditionSpec(type: .domain, value: "github"),
                         [RuleConditionSpec(type: .titleKeyword, value: "   ")], mode: .all)
        // La condición vacía no cuenta → basta con el dominio para cumplir.
        #expect(ClassificationEngine.matches(r, Bookmark(url: "https://github.com/x", title: "Cualquiera")))
    }

    @Test("allActions compone la acción primaria + las adicionales")
    func allActionsComposition() {
        let r = ClassificationRule(actionType: .setCategory, actionValue: "A")
        r.extraActions = [RuleActionSpec(type: .addTag, value: "B")]
        #expect(r.allActions.count == 2)
        #expect(r.allActions[0].type == .setCategory && r.allActions[0].value == "A")
        #expect(r.allActions[1].type == .addTag && r.allActions[1].value == "B")
    }

    @Test("Acciones múltiples: una regla que coincide aplica TODAS sus acciones")
    func multipleActions() {
        let category = BookmarkCategory(name: "Vídeos")
        let tag = Tag(name: "video")
        let rule = ClassificationRule(conditionType: .domain, conditionValue: "youtube",
                                      actionType: .setCategory, actionValue: category.id.uuidString)
        rule.extraActions = [RuleActionSpec(type: .addTag, value: tag.id.uuidString)]
        let bm = Bookmark(url: "https://youtube.com/watch?v=abc", title: "Un vídeo")
        ClassificationEngine.apply(to: bm, rules: [rule], categories: [category], tags: [tag])
        #expect(bm.category?.id == category.id)        // 1.ª acción: categoría asignada
        #expect(bm.tags.contains { $0.id == tag.id })  // 2.ª acción: etiqueta añadida
    }
}
