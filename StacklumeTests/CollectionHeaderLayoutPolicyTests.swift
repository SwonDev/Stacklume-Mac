import Testing

@Suite("Cabecera adaptable de la biblioteca")
struct CollectionHeaderLayoutPolicyTests {
    @Test("Apila identidad y controles cuando no caben en una sola fila")
    func stacksAtNarrowWidths() {
        #expect(
            CollectionHeaderLayoutPolicy.shouldStack(
                availableWidth: 308,
                identityIdealWidth: 205,
                controlsIdealWidth: 286,
                spacing: 12
            )
        )
    }

    @Test("Conserva la fila horizontal cuando hay espacio suficiente")
    func keepsWideHeaderHorizontal() {
        #expect(
            !CollectionHeaderLayoutPolicy.shouldStack(
                availableWidth: 560,
                identityIdealWidth: 205,
                controlsIdealWidth: 286,
                spacing: 12
            )
        )
    }

    @Test("El ancho exacto del contenido no fuerza una segunda fila")
    func exactFitRemainsHorizontal() {
        #expect(
            !CollectionHeaderLayoutPolicy.shouldStack(
                availableWidth: 503,
                identityIdealWidth: 205,
                controlsIdealWidth: 286,
                spacing: 12
            )
        )
    }
    @Test("El contador de resultados no cambia el número de filas")
    func resultCountDoesNotMoveControls() {
        let short = CollectionHeaderLayoutPolicy.shouldStack(availableWidth: 510, identityIdealWidth: 150, controlsIdealWidth: 220, spacing: 8)
        let long = CollectionHeaderLayoutPolicy.shouldStack(availableWidth: 510, identityIdealWidth: 480, controlsIdealWidth: 220, spacing: 8)
        #expect(short == long)
        #expect(!long)
    }
}
