import Testing

@Suite("Anchura segura de la ventana principal")
struct RootWindowLayoutMetricsTests {
    @Test("Reserva el sidebar restaurado a su ancho máximo")
    func minimumContainsMaximumSidebarWithoutOverflow() {
        let requiredWidth = RootWindowLayoutMetrics.sidebarMaximumWidth
            + RootWindowLayoutMetrics.libraryMinimumWidth
            + RootWindowLayoutMetrics.detailMinimumWidth
            + RootWindowLayoutMetrics.dividerAndInsetBudget

        #expect(RootWindowLayoutMetrics.minimumWindowWidth >= requiredWidth)
    }

    @Test("Mantiene el mínimo visual validado de 1180 puntos")
    func keepsValidatedMinimumWidth() {
        #expect(RootWindowLayoutMetrics.minimumWindowWidth == 1180)
    }
}
