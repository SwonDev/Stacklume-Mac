import Testing
import Foundation

// `ProjectWorkspaceStore` (y sus tipos) se compilan dentro del módulo de tests. Verifica
// la persistencia JSON de proyectos y, sobre todo, la DECODIFICACIÓN TOLERANTE: que
// añadir campos nuevos no pierda los datos antiguos.

@Suite("ProjectWorkspaceStore — persistencia de proyectos")
struct ProjectWorkspaceStoreTests {

    @Test("Round-trip encode/decode conserva todos los datos")
    func roundTrip() {
        let id = UUID().uuidString
        var ws = ProjectWorkspace(status: .paused, note: "hola", linkIDs: [UUID()])
        ws.commands = ["npm i zod"]
        ws.tasks = [ProjectTask(text: "tarea", done: true)]
        let json = ProjectWorkspaceStore.encodeAll([id: ws])
        #expect(ProjectWorkspaceStore.decodeAll(json)[id] == ws)
    }

    @Test("workspace(for:) devuelve uno vacío por defecto")
    func defaultWorkspace() {
        let ws = ProjectWorkspaceStore.workspace(for: UUID(), in: "")
        #expect(ws.status == .active)
        #expect(ws.note.isEmpty && ws.linkIDs.isEmpty && ws.tasks.isEmpty && ws.commands.isEmpty)
    }

    @Test("updating aplica el cambio y persiste")
    func updatingPersists() {
        let id = UUID()
        let json = ProjectWorkspaceStore.updating("", for: id) { $0.note = "x"; $0.status = .done }
        let ws = ProjectWorkspaceStore.workspace(for: id, in: json)
        #expect(ws.note == "x")
        #expect(ws.status == .done)
    }

    @Test("removing elimina el workspace del proyecto")
    func removingDeletes() {
        let id = UUID()
        let json = ProjectWorkspaceStore.updating("", for: id) { $0.note = "x" }
        let after = ProjectWorkspaceStore.removing(json, for: id)
        #expect(ProjectWorkspaceStore.decodeAll(after)[id.uuidString] == nil)
    }

    @Test("Decodificación tolerante: JSON antiguo sin los campos nuevos")
    func tolerantDecoding() {
        let id = UUID().uuidString
        let legacy = "{\"\(id)\":{\"status\":\"active\",\"note\":\"viejo\"}}"
        let map = ProjectWorkspaceStore.decodeAll(legacy)
        #expect(map[id]?.note == "viejo")
        #expect(map[id]?.tasks.isEmpty == true)
        #expect(map[id]?.commands.isEmpty == true)
    }
}
