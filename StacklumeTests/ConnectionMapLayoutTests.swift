import Testing

@Suite("Geometría del mapa de conexiones")
struct ConnectionMapLayoutTests {
    @Test("Mantiene todos los nodos dentro del lienzo")
    func pointsRemainInBounds() {
        for count in 0...12 {
            for compact in [false, true] {
                let points = ConnectionMapLayout.satellitePoints(count: count, compact: compact)
                #expect(points.count == min(count, ConnectionMapLayout.maximumVisibleSatellites))
                #expect(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
            }
        }
    }

    @Test("La disposición es determinista y no ocupa el centro")
    func layoutIsStable() {
        let first = ConnectionMapLayout.satellitePoints(count: 4, compact: false)
        let second = ConnectionMapLayout.satellitePoints(count: 4, compact: false)
        #expect(first == second)
        #expect(first.allSatisfy { $0 != ConnectionMapLayout.center })
    }

    @Test("La variante compacta acerca los satélites a un ancho estrecho")
    func compactLayoutUsesNarrowerHorizontalReach() {
        let wide = ConnectionMapLayout.satellitePoints(count: 4, compact: false)
        let compact = ConnectionMapLayout.satellitePoints(count: 4, compact: true)
        #expect(compact[0].x > wide[0].x)
        #expect(compact[1].x < wide[1].x)
    }

    @Test("La intensidad visual queda acotada")
    func strengthIsClamped() {
        #expect(ConnectionMapLayout.normalizedStrength(score: -10) == 0.22)
        #expect(ConnectionMapLayout.normalizedStrength(score: 1) == 0.5)
        #expect(ConnectionMapLayout.normalizedStrength(score: 20) == 1)
    }
}
