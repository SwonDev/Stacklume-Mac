import Foundation
import Testing

@Suite("Asistente IA — investigación con contexto")
struct AssistantResearchTests {
    @Test("Los campos reales del piloto conservan integración cotidiana y full-stack sin inventar una identidad")
    @MainActor
    func acceptsPilotFitAndTechnicalAdjective() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let fit = "PocketBase encaja como backend ligero y único archivo, ideal para proyectos que buscan simplicidad y fácil integración sin complejidad adicional."
        let difference = "T1T0Dev/E-COMMERCE utiliza un stack full-stack (React, Express, MySQL) y está diseñado para entornos empresariales reales, mientras que PocketBase es un backend minimalista en un solo archivo."
        let result = try await composeFixture(plan: plan, dossier: pilotBackendDossier(), spanish: true, outputTokens: 4096) { _ in
            structured([component("engine", choice: "B1", alternative: "W2", fit: fit, difference: difference)])
        }
        #expect(result.issues.isEmpty)
        #expect(result.rounds == 1)
        #expect(result.text.contains("[B1]"))
        #expect(result.text.contains("[W2]"))
        let sources = Dictionary(uniqueKeysWithValues: pilotBackendDossier().indexedSources)
        let actualDifference = String(difference.dropLast()) + " sin interfaz frontend."
        #expect(AssistantResearchAnswer.structuredAttributionIssues(in: actualDifference, allowedIDs: ["B1", "W2"], sources: sources).isEmpty)
        for wrongSource in ["B1", "B3"] {
            #expect(!AssistantResearchAnswer.structuredAttributionIssues(in: difference, allowedIDs: [wrongSource], sources: sources).isEmpty)
        }
    }

    @Test("La comparación real no puede negar una capacidad sin evidencia de esa ausencia")
    @MainActor
    func rejectsUnsupportedCapabilityAbsence() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let fit = "PocketBase encaja como backend ligero y único archivo, ideal para proyectos que buscan simplicidad y fácil integración sin complejidad adicional."
        for absence in ["sin interfaz frontend", "sin almacenamiento de archivos"] {
            let difference = "T1T0Dev/E-COMMERCE utiliza un stack full-stack (React, Express, MySQL) y está diseñado para entornos empresariales reales, mientras que PocketBase es un backend minimalista en un solo archivo " + absence + "."
            let result = try await composeFixture(plan: plan, dossier: pilotBackendDossier(), spanish: true, outputTokens: 4096) { _ in
                structured([component("engine", choice: "B1", alternative: "W2", fit: fit, difference: difference)])
            }
            #expect(!result.issues.isEmpty)
            #expect(result.rounds == 2)
            #expect(!result.text.contains("## Backend"))
        }
    }

    @Test("Una ausencia explícita pertenece a su sujeto y no se presta a la otra opción")
    @MainActor
    func attributesBackedAbsenceToItsSubject() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let minimal = AssistantResearchSource(title: "EngineWithoutUI", url: "https://example.org/minimal", bookmarkID: nil,
            summary: "EngineWithoutUI implementa backend y API sin interfaz frontend.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        let panel = AssistantResearchSource(title: "EngineWithUI", url: "https://example.org/panel", bookmarkID: nil,
            summary: "EngineWithUI implementa backend y API con interfaz frontend y panel de administración.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        var dossier = AssistantResearchDossier()
        dossier.append(.init(sources: [minimal, panel], candidateCount: 2), query: .init(facet: .engine, text: "backend"), web: false)
        for (difference, accepted) in [("EngineWithoutUI funciona sin interfaz frontend, frente a EngineWithUI.", true),
                                        ("EngineWithUI funciona sin interfaz frontend, frente a EngineWithoutUI.", false),
                                        ("EngineWithoutUI sirve la API, mientras que EngineWithUI funciona sin interfaz frontend.", false)] {
            let result = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4096) { _ in
                structured([component("engine", choice: "B1", alternative: "B2", fit: "Implementa la API del programa.", difference: difference)])
            }
            #expect(result.issues.isEmpty == accepted)
        }
    }

    @Test("El adjetivo técnico no permite identidades ajenas ni capacidades de exportación, compatibilidad o NoSQL")
    @MainActor
    func preservesIdentityAndCapabilityRejections() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        for fit in ["PocketBase exporta archivos en distintos formatos.",
                    "PocketBase garantiza compatibilidad con el programa.",
                    "PocketBase conserva los registros en NoSQL."] {
            let result = try await composeFixture(plan: plan, dossier: pilotBackendDossier(), spanish: true, outputTokens: 4096) { _ in
                structured([component("engine", choice: "B1", fit: fit)])
            }
            #expect(!result.issues.isEmpty)
        }
        var sources = Dictionary(uniqueKeysWithValues: pilotBackendDossier().indexedSources)
        sources["B4"] = AssistantResearchSource(title: "SQL-Server", url: "https://learn.microsoft.com/sql/", bookmarkID: nil,
            summary: "SQLServer es una base de datos para los registros del programa.", evidence: "", origin: .library, facets: [.database], collection: nil, tags: [])
        for name in ["SQL-Server", "sql-server", "SQLServer", "sqlserver"] {
            let prose = name + " conserva los registros frente a PocketBase."
            #expect(AssistantResearchAnswer.structuredAttributionIssues(in: prose, allowedIDs: ["B1", "B4"], sources: sources).isEmpty)
            #expect(!AssistantResearchAnswer.structuredAttributionIssues(in: prose, allowedIDs: ["B1"], sources: sources).isEmpty)
        }
    }

    private func pilotBackendDossier() -> AssistantResearchDossier {
        let pocket = AssistantResearchSource(title: "PocketBase - Open Source backend in 1 file", url: "https://pocketbase.io/", bookmarkID: nil,
            summary: "PocketBase es un backend de código abierto que se instala en a lo sumo un archivo y proporciona una base de datos en tiempo real, autenticación, almacenamiento de archivos y panel de administración. Está diseñado para integrarse fácilmente con cualquier pila tecnológica frontend, lo que facilita su adopción en proyectos existentes. Su interfaz de usuario es ligera y la documentación está disponible en el sitio web oficial. La herramienta está disponible bajo una licencia de código abierto que permite su uso comercial y de código abierto sin restricciones. Ideal para desarrolladores que buscan una solución ligera y flexible sin complejidad adicional.",
            evidence: "", origin: .library, facets: [.engine, .database, .storage], collection: nil, tags: [])
        let commerce = AssistantResearchSource(title: "GitHub - T1T0Dev/E-COMMERCE: Aplicación web de e-commerce desarrollada ...", url: "https://github.com/T1T0Dev/E-COMMERCE", bookmarkID: nil,
            summary: "Aplicación web de e-commerce desarrollada con React ( front-end ), Express (back-end) y MySQL ( base de datos ). Está pensada para un entorno realista de negocio con gestión de roles y funcionalidades específicas para cada usuario.",
            evidence: "", origin: .web, facets: [.engine], collection: nil, tags: [])
        let api = AssistantResearchSource(title: "FastAPI", url: "https://fastapi.tiangolo.com/", bookmarkID: nil,
            summary: "FastAPI es un framework backend para implementar API.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        var dossier = AssistantResearchDossier()
        dossier.append(.init(sources: [pocket, commerce, api], candidateCount: 3), query: .init(facet: .engine, text: "backend"), web: false)
        return dossier
    }

    @Test("El formato LFM2 explica nombre y etiquetas por partes sin argumentos de ejemplo copiables")
    @MainActor
    func sendsExactToolSyntaxWithoutAcceptingPlaceholders() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let result = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { round in
            #expect(round.request.components(separatedBy: "<|tool_call_start|>").count == 2)
            #expect(round.request.components(separatedBy: "<|tool_call_end|>").count == 2)
            let sent = round.instructions + "\n" + round.request
            #expect(!sent.contains("NOMBRE_ARGUMENTO"))
            #expect(!sent.contains("TEXTO_GENERADO"))
            #expect(!sent.contains("entregar_propuesta("))
            #expect(round.request.contains("abre un corchete ["))
            #expect(round.request.contains("cierra el corchete ]"))
            #expect(round.request.contains("nombre exacto entregar_propuesta"))
            #expect(round.request.contains("No traduzcas ni cambies el nombre"))
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(round.deliveryTool.parametersJSON.utf8)) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(properties["NOMBRE_ARGUMENTO"] == nil)
            #expect(!round.deliveryTool.parametersJSON.contains("TEXTO_GENERADO"))
            return delivery("{\"NOMBRE_ARGUMIENTO\":\"Propuesta de selección de backend\"}")
        }
        #expect(!result.issues.isEmpty)
        #expect(result.rounds == 2)
        #expect(!result.text.contains("TEXTO_GENERADO"))
        #expect(!result.text.contains("«FastAPI»"))
    }

    @Test("Los argumentos planos conservan una elección y una alternativa provisional sin depender de arrays Pythonic")
    @MainActor
    func deliversFlatParametersWithExactRouting() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let arguments: [String: String] = ["r0_choiceSourceID": "S1", "r0_alternativeSourceID": "sin_fuente",
            "r0_fit": "Implementa la API del programa.",
            "r0_difference": "Alternativa provisional sin respaldo de fuentes; falta decidir si se necesita operación local.",
            "r0_verification": "Comprobar las políticas de acceso antes de publicar.", "integration": ""]
        let raw = String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
        let result = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in delivery(raw) }
        #expect(result.issues.isEmpty)
        #expect(result.rounds == 1)
        #expect(result.text.contains("«FastAPI»"))
        #expect(result.text.contains("[B1]"))
        #expect(!result.text.contains("sin_fuente"))
    }

    @Test("La entrega plana rechaza tipos, campos e IDs ajenos, y el sentinel no elimina el requisito de respaldo provisional")
    @MainActor
    func rejectsMalformedFlatArguments() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let valid: [String: Any] = ["r0_choiceSourceID": "S1", "r0_alternativeSourceID": "sin_fuente",
            "r0_fit": "Implementa la API del programa.",
            "r0_difference": "Alternativa provisional sin respaldo de fuentes; falta precisar la operación del programa.",
            "r0_verification": "Comprobar las políticas de acceso antes de publicar.", "integration": ""]
        var missing = valid; missing["r0_fit"] = nil
        var extra = valid; extra["roleID"] = "engine"
        var wrongType = valid; wrongType["r0_fit"] = 42
        var nullID = valid; nullID["r0_choiceSourceID"] = NSNull()
        var unbacked = valid; unbacked["r0_choiceSourceID"] = "sin_fuente"
        var inputs = [missing, extra, wrongType, nullID, unbacked]
        for alias in ["B1", "S01", "s1", "S99", "None", "sinFuente", " sin_fuente "] {
            var input = valid; input["r0_choiceSourceID"] = alias; inputs.append(input)
        }
        for input in inputs {
            let args = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
            let result = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in delivery(args) }
            #expect(!result.issues.isEmpty)
            #expect(result.rounds == 2)
            #expect(!result.text.contains("«FastAPI»"))
        }
    }

    @Test("Los prefijos indexados preservan roleIDs con guiones y evitan colisiones por normalización")
    func routesRoleIDsWithoutNormalizingTheirKeys() throws {
        let roles = ["api-v1", "api_v1"]
        let spec = AssistantResearchToolSpecification.make(roles: roles,
            aliases: [roles[0]: ["S1": "B1"], roles[1]: ["S1": "W1"]], spanish: true, needsIntegration: true)
        #expect(spec.roles == [.init(roleID: "api-v1", prefix: "r0"), .init(roleID: "api_v1", prefix: "r1")])
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(spec.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties.count == 11)
        #expect(Set(schema["required"] as! [String]) == Set(properties.keys))
        var input: [String: String] = ["integration": "Conectar las operaciones del programa."]
        for binding in spec.roles {
            for field in AssistantResearchToolSpecification.fields { input[binding.prefix + "_" + field] = "Texto del modelo, con «comillas» y puntuación (área)." }
            input[binding.prefix + "_choiceSourceID"] = "S1"
            input[binding.prefix + "_alternativeSourceID"] = AssistantResearchToolSpecification.noSource
        }
        let raw = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        let payload = spec.componentArguments(raw)
        #expect(payload.issues.isEmpty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(payload.text.utf8)) as? [String: Any])
        let rows = try #require(object["components"] as? [[String: Any]])
        #expect(rows.compactMap { $0["roleID"] as? String } == roles)
        #expect(rows.allSatisfy { $0["alternativeSourceID"] is NSNull })
        #expect(rows.allSatisfy { $0["fit"] as? String == "Texto del modelo, con «comillas» y puntuación (área)." })
    }

    private func delivery(_ arguments: String, name: String = AssistantResearchToolSpecification.name,
                          text: String = "", reachedLimit: Bool = false,
                          roles: [AssistantResearchToolSpecification.RoleBinding]? = nil) -> AssistantResearchToolOutput {
        var raw = arguments
        if let data = arguments.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["components"] as? [[String: Any]] {
            var flat: [String: Any] = [:], seen = Set<String>()
            if let integration = object["integration"] { flat["integration"] = integration }
            for (offset, row) in rows.enumerated() {
                if let role = row["roleID"] as? String, !seen.insert(role).inserted { flat["duplicateRole"] = role }
                let prefix: String
                if let roles {
                    guard let binding = roles.first(where: { $0.roleID == row["roleID"] as? String }) else {
                        flat["unknownRole"] = row["roleID"] ?? ""; continue
                    }
                    prefix = binding.prefix
                } else { prefix = "r\(offset)" }
                for (field, value) in row where field != "roleID" {
                    flat[prefix + "_" + field] = value is NSNull ? AssistantResearchToolSpecification.noSource : value
                }
            }
            raw = String(data: try! JSONSerialization.data(withJSONObject: flat), encoding: .utf8)!
        }
        return .init(calls: [.init(name: name, argumentsJSON: raw)], generatedText: text, reachedLengthLimit: reachedLimit)
    }

    @Test("Una propuesta exige una única llamada de entrega exacta, no texto JSON ni llamadas ajenas")
    @MainActor
    func requiresOneExactDeliveryCall() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let args = structured([component("engine", choice: "S1", fit: "Implementa la API del programa.")])
        let valid = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in delivery(args) }
        #expect(valid.issues.isEmpty)
        for output in [AssistantResearchToolOutput(calls: [], generatedText: args, reachedLengthLimit: false),
                       delivery(args, name: "crear_enlace"), delivery(args, name: "Entregar_propuesta"),
                       AssistantResearchToolOutput(calls: [.init(name: AssistantResearchToolSpecification.name, argumentsJSON: args),
                                                         .init(name: AssistantResearchToolSpecification.name, argumentsJSON: args)], generatedText: "", reachedLengthLimit: false),
                       delivery(args, reachedLimit: true)] {
            let result = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in output }
            #expect(!result.issues.isEmpty)
            #expect(result.rounds == 2)
            #expect(!result.text.contains("«FastAPI»"))
        }
    }

    @Test("El schema enviado a la herramienta coincide con el contrato y conserva roles y aliases reales")
    @MainActor
    func sendsActualDeliverySchema() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
        let result = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { round in
            #expect(round.request.contains("Llama a entregar_propuesta una sola vez"))
            #expect(!round.request.contains("ESQUEMA_JSON"))
            let schemaData = try #require(round.deliveryTool.parametersJSON.data(using: .utf8))
            let schema = try #require(try JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
            #expect(schema["additionalProperties"] as? Bool == false)
            #expect(round.sourceAliasesByRole["engine"] == ["S1": "B1", "S2": "B2"])
            #expect(round.sourceAliasesByRole["database"] == ["S1": "B2"])
            return delivery(structured([component("engine", choice: "S1", fit: "Implementa la API del programa."),
                                        component("database", choice: "S1", fit: "Conserva los datos estructurados del programa.")],
                                      integration: "Comprueba las políticas de acceso antes de conectar las operaciones."))
        }
        #expect(result.issues.isEmpty)
        #expect(result.text.contains("[B1]"))
        #expect(result.text.contains("[B2]"))
    }

    @Test("Los argumentos de una toolcall mantienen las guardias de IDs, campos, idioma, respaldo y conjunto completo")
    @MainActor
    func preservesGuardsForDeliveredArguments() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
        let backend = component("engine", choice: "S1", fit: "Implementa la API del programa.")
        let database = component("database", choice: "S1", fit: "Conserva los datos estructurados del programa.")
        var unknownAlias = backend; unknownAlias["choiceSourceID"] = "B1"
        var unknownField = backend; unknownField["extra"] = true
        var english = backend; english["fit"] = "Handles authentication securely and persists user records."
        var crossedIdentity = backend; crossedIdentity["fit"] = "Supabase ofrece la API del programa."
        var wrongCapability = backend; wrongCapability["fit"] = "Guarda los archivos digitales del programa."
        let integration = "Comprueba las políticas de acceso antes de conectar las operaciones."
        for rows in [[unknownAlias, database], [unknownField, database], [english, database],
                     [crossedIdentity, database], [wrongCapability, database], [backend, backend, database], [backend]] {
            let result = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096,
                detectedLanguage: { $0.contains("Handles") ? "en" : "es" }) { round in
                    delivery(structured(rows, integration: integration), roles: round.deliveryTool.roles)
                }
            #expect(!result.issues.isEmpty)
            #expect(result.rounds == 2)
            #expect(!result.text.contains("## Encaje del conjunto"))
        }
        var rounds: [AssistantResearchRound] = []
        let repaired = try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { round in
            rounds.append(round)
            if round.purpose == .composition { return delivery(structured([unknownAlias, database], integration: integration)) }
            #expect(round.sourceAliasesByRole.keys.sorted() == ["engine"])
            #expect(round.request.contains("Alias"))
            return delivery(structured([backend], integration: integration))
        }
        #expect(repaired.issues.isEmpty)
        #expect(rounds.count == 2)
        #expect(rounds.allSatisfy { $0.maximumTokens == 4096 && !$0.publishesPartialText })
        #expect(repaired.text.contains("«FastAPI»"))
        #expect(repaired.text.contains("«Supabase»"))
        #expect(repaired.text.contains("[B1]"))
        #expect(repaired.text.contains("[B2]"))
    }

    @Test("La cancelación durante una entrega impide reparar o publicar el candidato")
    @MainActor
    func cancelsDeliveredCandidateBeforeRepair() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        var requests = 0
        let task = Task {
            try await AssistantResearchComposer.composeToolCalls(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in
                requests += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return delivery(structured([component("engine", choice: "S1", fit: "Implementa la API del programa.")]))
            }
        }
        do { _ = try await task.value; Issue.record("Se publicó una entrega cancelada.") }
        catch is CancellationError { }
        #expect(requests == 1)
    }
    private func component(_ role: String, choice: String?, alternative: String? = nil,
                           fit: String = "Propuesta provisional sin respaldo de fuentes; falta precisar la operación del programa.",
                           difference: String = "Alternativa provisional sin respaldo de fuentes; falta decidir si se necesita operación local.",
                           verification: String = "Comprobar las políticas de acceso antes de publicar.") -> [String: Any] {
        ["roleID": role, "choiceSourceID": choice as Any? ?? NSNull(), "alternativeSourceID": alternative as Any? ?? NSNull(),
         "fit": fit, "difference": difference, "verification": verification]
    }

    private func structured(_ components: [[String: Any]], integration: String = "") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["components": components, "integration": integration], options: [.sortedKeys]), encoding: .utf8)!
    }

    /// Las fixtures eligen registros B/W concretos. Su respuesta usa únicamente
    /// el alias que el compositor ha enviado para ese registro y ese papel.
    @MainActor
    private func composeFixture(plan: AssistantResearchPlan, dossier: AssistantResearchDossier,
                                spanish: Bool, outputTokens: Int, additionalEvidence: String = "",
                                detectedLanguage: (@Sendable (String) -> String?)? = nil,
                                generate: @MainActor (AssistantResearchRound) async throws -> String) async throws -> AssistantResearchComposition {
        try await AssistantResearchComposer.compose(plan: plan, dossier: dossier, spanish: spanish, outputTokens: outputTokens,
            additionalEvidence: additionalEvidence, detectedLanguage: detectedLanguage) { round in
            let raw = try await generate(round)
            guard let data = raw.data(using: .utf8), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["components"] as? [[String: Any]] else { return raw }
            object["components"] = rows.map { row in
                var result = row
                let aliases = (row["roleID"] as? String).flatMap { round.sourceAliasesByRole[$0] } ?? [:]
                for field in ["choiceSourceID", "alternativeSourceID"] {
                    if let id = row[field] as? String, let alias = aliases.first(where: { $0.value == id })?.key { result[field] = alias }
                }
                return result
            }
            return String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        }
    }

    @Test("Los aliases se resuelven sólo en su papel y no aceptan normalizaciones ni IDs globales")
    @MainActor
    func resolvesOnlyExactRoleAliases() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
        let valid = try await AssistantResearchComposer.compose(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { round in
            #expect(round.sourceAliasesByRole["engine"]?["S1"] == "B1")
            #expect(round.sourceAliasesByRole["database"]?["S1"] == "B2")
            #expect(round.sourceAliasesByRole["database"]?["S2"] == nil)
            return structured([component("engine", choice: "S1", fit: "Implementa la API del programa."),
                               component("database", choice: "S1", fit: "Conserva los datos estructurados del programa.")],
                              integration: "Comprueba las políticas de acceso antes de conectar las operaciones.")
        }
        #expect(valid.issues.isEmpty)
        #expect(valid.text.contains("«FastAPI»"))
        #expect(valid.text.contains("«Supabase»"))
        #expect(valid.text.contains("[B1]"))
        #expect(valid.text.contains("[B2]"))
        #expect(!valid.text.contains("[S1]"))
        for invalid in ["S01", "s1", " S1 ", "S99", "B1", "S2"] {
            let result = try await AssistantResearchComposer.compose(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in
                structured([component("engine", choice: "S1", fit: "Implementa la API del programa."),
                            component("database", choice: invalid, fit: "Conserva los datos estructurados del programa.")],
                           integration: "Comprueba las políticas de acceso antes de conectar las operaciones.")
            }
            #expect(result.issues.contains { $0.contains("Alias") })
            #expect(!result.text.contains("Conserva los datos estructurados"))
        }
    }

    @Test("El esquema del prompt enumera aliases reales y exige un componente por cada papel solicitado")
    @MainActor
    func sendsParseableSchemaWithExactRolesAndAliases() async throws {
        for request in ["Quiero crear una app con backend.", "Quiero crear una app con backend y base de datos."] {
            let plan = AssistantResearchPlan.make(request: request, priorUserRequests: [])
            _ = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { round in
                let data = try #require(round.deliveryTool.parametersJSON.data(using: .utf8))
                let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let properties = try #require(schema["properties"] as? [String: Any])
                #expect(schema["additionalProperties"] as? Bool == false)
                #expect(round.deliveryTool.roles.map(\.roleID) == plan.responseFacets.map(\.rawValue))
                #expect(Set(schema["required"] as! [String]) == Set(properties.keys))
                #expect(properties.count == plan.responseFacets.count * 5 + 1)
                for binding in round.deliveryTool.roles {
                    for field in AssistantResearchToolSpecification.fields {
                        let property = properties[binding.prefix + "_" + field] as! [String: Any]
                        #expect(property["type"] as? String == "string")
                        if field == "choiceSourceID" || field == "alternativeSourceID" {
                            let values = property["enum"] as! [String]
                            #expect(Set(values) == Set(round.sourceAliasesByRole[binding.roleID]!.keys).union([AssistantResearchToolSpecification.noSource]))
                        } else {
                            #expect((property["description"] as? String)?.contains("español") == true)
                            if field == "verification" { #expect((property["description"] as? String)?.contains("futura") == true) }
                        }
                    }
                }
                let integration = properties["integration"] as! [String: Any]
                if plan.responseFacets.count == 1 { #expect(integration["const"] as? String == "") }
                return structured(plan.responseFacets.map { component($0.rawValue, choice: nil) }, integration: plan.responseFacets.count > 1 ? "Comprueba las políticas de acceso antes de publicar." : "")
            }
        }
    }

    @Test("La reparación exclusiva del encaje exige cero componentes y conserva las elecciones aceptadas")
    @MainActor
    func schemasIntegrationOnlyRepairWithoutComponentVariants() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { round in
            if round.purpose == .composition {
                return structured([component("engine", choice: "B1", fit: "Implementa la API del programa."),
                                   component("database", choice: "B2", fit: "Conserva los datos estructurados del programa.")])
            }
            #expect(round.sourceAliasesByRole.isEmpty)
            let data = try #require(round.deliveryTool.parametersJSON.data(using: .utf8))
            let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(properties.keys) == ["integration"])
            #expect(round.deliveryTool.roles.isEmpty)
            let integration = try #require(properties["integration"] as? [String: Any])
            #expect(integration["minLength"] as? Int == 1)
            return structured([], integration: "Comprueba las políticas de acceso antes de conectar las operaciones.")
        }
        #expect(result.issues.isEmpty)
        #expect(result.rounds == 2)
        #expect(result.text.contains("«FastAPI»"))
        #expect(result.text.contains("«Supabase»"))
    }

    @Test("Los DTO rechazan la cita real con letra equivocada y el despliegue como almacenamiento")
    @MainActor
    func rejectsWrongIDAndRoleInStructuredOutput() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con búsqueda, almacenamiento y despliegue.", priorUserRequests: [])
        var dossier = AssistantResearchDossier()
        let elastic = AssistantResearchSource(title: "Elasticsearch", url: "https://www.elastic.co/es/elasticsearch", bookmarkID: nil,
            summary: "Elasticsearch es un motor de búsqueda e indexación.", evidence: "", origin: .web, facets: [.search], collection: nil, tags: [])
        let deploy = AssistantResearchSource(title: "Seenode", url: "https://seenode.com/", bookmarkID: nil,
            summary: "Seenode ofrece hosting para el despliegue de aplicaciones y bases de datos.", evidence: "", origin: .library, facets: [.deployment], collection: nil, tags: [])
        dossier.append(.init(sources: [elastic, deploy], candidateCount: 2), query: .init(facet: .overview, text: "software"), web: true)
        let result = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4096) { _ in
            structured([component("search", choice: "B1", fit: "Recupera contenido del catálogo con un índice."),
                        component("storage", choice: "B2", fit: "Conserva los archivos digitales del catálogo."),
                        component("deployment", choice: "B2", fit: "Permite desplegar el programa en un servidor.")], integration: "Comprueba las políticas antes de publicar el catálogo.")
        }
        #expect(result.issues.contains { $0.contains("B1") })
        #expect(result.sources["B2"]?.title == "Seenode")
        #expect(result.sources["W1"]?.title == "Elasticsearch")
        #expect(result.issues.contains { $0.contains("Almacenamiento") })
        #expect(!result.text.contains("Recupera contenido del catálogo"))
        #expect(!result.text.contains("Conserva los archivos digitales"))
    }

    @Test("El DTO conserva una frase normal y rechaza productos ajenos explícitos o sin comillas")
    @MainActor
    func checksStructuredAttributionWithoutTreatingInitialVerbAsProduct() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        for fit in ["Ofrece API para las operaciones del programa.", "FastAPI ofrece API para las operaciones del programa."] {
            let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in
                structured([component("engine", choice: "B1", fit: fit)])
            }
            #expect(result.issues.isEmpty)
            #expect(result.rounds == 1)
        }
        for fit in ["Supabase ofrece API para las operaciones del programa.", "«Supabase» ofrece API para las operaciones del programa."] {
            let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in
                structured([component("engine", choice: "B1", fit: fit)])
            }
            #expect(result.issues.contains { $0.lowercased().contains("supabase") })
            #expect(!result.text.contains(fit))
        }
        let data = backendDossier()
        var sources = Dictionary(uniqueKeysWithValues: data.indexedSources.map { ($0.id, $0.source) })
        sources["B3"] = .init(title: "PocketBase", url: "https://pocketbase.io/", bookmarkID: nil,
            summary: "PocketBase ofrece backend y API.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        #expect(AssistantResearchAnswer.structuredAttributionIssues(in: "Supabase reduce el desarrollo frente a FastAPI.", allowedIDs: ["B1", "B2"], sources: sources).isEmpty)
        #expect(!AssistantResearchAnswer.structuredAttributionIssues(in: "Supabase reduce el desarrollo inicial.", allowedIDs: ["B1"], sources: sources).isEmpty)
        for difference in ["PocketBase reduce el desarrollo inicial.", "«PocketBase» reduce el desarrollo inicial."] {
            #expect(!AssistantResearchAnswer.structuredAttributionIssues(in: difference, allowedIDs: ["B1", "B2"], sources: sources).isEmpty)
        }
    }

    @Test("El DTO rechaza campos ausentes, tipos erróneos, papeles duplicados y citas libres")
    @MainActor
    func enforcesStructuredFieldsAndIdentity() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let valid = component("engine", choice: "B1", fit: "Implementa las operaciones del servidor mediante una API.")
        var missing = valid; missing["verification"] = nil
        var wrongType = valid; wrongType["choiceSourceID"] = 1
        var extra = valid; extra["technology"] = "FastAPI"
        var inlineCitation = valid; inlineCitation["fit"] = "Implementa las operaciones del servidor mediante una API [W999]."
        var repeatedChoice = valid; repeatedChoice["alternativeSourceID"] = "B1"
        for rows in [[missing], [wrongType], [extra], [valid, valid], [inlineCitation], [repeatedChoice], [component("storage", choice: "B1")]] {
            let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in structured(rows) }
            #expect(!result.issues.isEmpty)
            #expect(result.rounds == 2)
            #expect(!result.text.contains("W999"))
        }
    }

    @Test("El idioma se valida en cada campo y el encaje del conjunto es obligatorio")
    @MainActor
    func enforcesStructuredLanguageAndIntegration() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
        let backend = component("engine", choice: "B1", fit: "Implementa las operaciones del servidor mediante una API.")
        let database = component("database", choice: "B2", fit: "Conserva los datos estructurados del programa.")
        let noIntegration = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in structured([backend, database]) }
        #expect(noIntegration.issues.contains { $0.contains("encaje") })
        for field in ["fit", "difference", "verification"] {
            var english = backend; english[field] = "Handles authentication securely and persists records."
            let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096,
                detectedLanguage: { $0.contains("Handles") ? "en" : "es" }) { _ in
                structured([english, database], integration: "Comprueba las políticas de acceso antes de conectar las operaciones.")
            }
            #expect(result.issues.contains { $0.contains("español") })
            #expect(!result.text.contains("Handles"))
        }
    }

    @Test("La reparación fallida informa su diagnóstico real y no conserva el error anterior")
    @MainActor
    func reportsLatestRejectedRepair() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096,
            detectedLanguage: { $0.contains("Metadata") ? "en" : "es" }) { round in
            if round.purpose == .composition { return structured([component("engine", choice: "W999")]) }
            return structured([component("engine", choice: "B1", fit: "Implementa la API del programa.", verification: "Metadata not verified")])
        }
        #expect(result.issues.contains { $0.contains("español") })
        #expect(!result.issues.contains { $0.contains("W999") })
        #expect(!result.text.contains("Metadata"))
    }

    @Test("El encaje no se publica si las decisiones de sus componentes siguen rechazadas")
    @MainActor
    func withholdsIntegrationWithoutAcceptedComponents() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
        let integration = "Se seleccionaron fuentes que cubren cada papel solicitado."
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in
            structured([component("engine", choice: "W999"), component("database", choice: "W999")], integration: integration)
        }
        #expect(!result.text.contains(integration))
        #expect(!result.text.contains("## Encaje del conjunto"))
        #expect(result.issues.contains { $0.contains("encaje") })
    }

    @Test("La explicación no puede añadir almacenamiento a una fuente que sólo respalda API")
    @MainActor
    func rejectsUnsupportedCapabilityInStructuredOutput() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4096) { _ in
            structured([component("engine", choice: "B1", fit: "Ofrece almacenamiento de archivos para los recursos digitales.")])
        }
        #expect(result.issues.contains { $0.contains("Almacenamiento") })
        #expect(!result.text.contains("Ofrece almacenamiento de archivos"))
    }

    @Test("La identidad inglesa de una fuente no altera el idioma de la explicación validada")
    @MainActor
    func validatesProseSeparatelyFromEnglishSourceTitle() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        var dossier = AssistantResearchDossier()
        dossier.append(.init(sources: [.init(title: "The framework for building APIs with modern code", url: "https://example.org/api", bookmarkID: nil,
            summary: "Framework backend para implementar API.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])], candidateCount: 1),
            query: .init(facet: .engine, text: "backend"), web: false)
        let result = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4096,
            detectedLanguage: { $0.contains("The framework") ? "en" : "es" }) { _ in
            structured([component("engine", choice: "B1", fit: "Implementa las operaciones del servidor mediante una API.")])
        }
        #expect(result.issues.isEmpty)
        #expect(result.text.contains("The framework for building APIs with modern code"))
        #expect(result.text.contains("[B1]"))
    }
    @Test("La salida directa de LFM sigue visible y los pensamientos explícitos se separan también en medio del texto")
    func separatesExplicitThoughtWithoutHidingPlainAnswer() {
        let direct = AssistantResearchAnswer.splitGeneratedText("La API debe aplicar las políticas de acceso.")
        #expect(direct.reasoning.isEmpty)
        #expect(direct.answer == "La API debe aplicar las políticas de acceso.")
        let open = AssistantResearchAnswer.splitGeneratedText("<think>Debo contrastar las fuentes")
        #expect(open.reasoning == "Debo contrastar las fuentes")
        #expect(open.answer.isEmpty)
        let complete = AssistantResearchAnswer.splitGeneratedText("<think>Contrastar</think>La API aplica permisos.")
        #expect(complete.reasoning == "Contrastar")
        #expect(complete.answer == "La API aplica permisos.")
        let middle = AssistantResearchAnswer.splitGeneratedText("La API aplica permisos. <think>Contrastar</think> Verifica la carga.")
        #expect(middle.reasoning == "Contrastar")
        #expect(middle.answer == "La API aplica permisos.  Verifica la carga.")
        let partial = AssistantResearchAnswer.splitGeneratedText("La API aplica permisos. <think>Pendiente")
        #expect(partial.reasoning == "Pendiente")
        #expect(partial.answer == "La API aplica permisos.")
        let legacy = AssistantResearchAnswer.splitGeneratedText("Contrastar</think>La API aplica permisos.")
        #expect(legacy.reasoning == "Contrastar")
        #expect(legacy.answer == "La API aplica permisos.")
    }

    @Test("Una fuente enviada puede respaldar varios papeles aunque no entre en el corte de cada consulta")
    @MainActor
    func permitsSentEvidenceAcrossRoles() async throws {
        var dossier = AssistantResearchDossier()
        var sources = (1...10).map { number in
            AssistantResearchSource(title: "Base de datos \(number)", url: "https://example.org/database/\(number)", bookmarkID: nil,
                summary: "Base de datos SQL para conservar registros.", evidence: "", origin: .library, facets: [.database], collection: nil, tags: [])
        }
        sources.append(.init(title: "PocketBase", url: "https://pocketbase.io/", bookmarkID: nil,
            summary: "PocketBase ofrece backend con API, base de datos y almacenamiento de archivos.", evidence: "", origin: .library, facets: [.engine, .storage], collection: nil, tags: []))
        dossier.append(.init(sources: sources, candidateCount: sources.count), query: .init(facet: .overview, text: "software"), web: false)
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app: backend y base de datos.", priorUserRequests: [])
        let result = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4_096) { round in
            #expect(round.purpose == .composition)
            #expect(Set(AssistantResearchAnswer.citationTokens(in: round.request)).count <= 4)
            return structured([component("engine", choice: "B1", fit: "Ofrece API y base de datos para el programa."),
                               component("database", choice: "B1", fit: "Conserva la base de datos del programa.")],
                              integration: "La base de datos incluida evita añadir otro servicio sin justificarlo.")
        }
        #expect(result.issues == [])
        #expect(result.rounds == 1)
    }

    @Test("El contrato de respuesta cierra el contexto y la reparación evita copiar el borrador defectuoso")
    @MainActor
    func outputContractFollowsEvidence() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        _ = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { round in
            let contract = round.request.range(of: "FORMATO DE RESPUESTA")
            let evidence = round.request.range(of: "https://fastapi.tiangolo.com/")
            #expect(contract != nil)
            if let contract, let evidence { #expect(contract.lowerBound > evidence.lowerBound) }
            #expect(!round.request.contains("Northflank"))
            if round.purpose == .composition {
                return structured([component("engine", choice: "W999", fit: "«Northflank» implementa las cuentas del programa.")])
            }
            return structured([component("engine", choice: "B1", alternative: "B2", fit: "Ofrece API para el programa.", difference: "Incluye usuarios y API para reducir el desarrollo inicial.")])
        }
    }

    @Test("La app coloca los rótulos desde el DTO y conserva el rechazo de la prosa no estructurada")
    @MainActor
    func preservesModelWordsWithoutInventingSections() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let valid = structured([component("engine", choice: "B1", alternative: "B2", fit: "Ofrece API para el programa.", difference: "Incluye usuarios y API para reducir el desarrollo inicial.")])
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { _ in valid }
        #expect(result.issues == [])
        #expect(result.rounds == 1)
        let unstructured = "Todavía no he podido decidir cómo separar los servicios de este programa."
        let unresolved = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { _ in unstructured }
        #expect(!unresolved.text.contains(unstructured))
        #expect(!unresolved.issues.isEmpty)
    }
    @Test("El presupuesto de una composición única incluye el razonamiento de los seis papeles")
    @MainActor
    func oneCompositionPreservesReasoningBudget() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app: frontend, backend, base de datos, búsqueda, almacenamiento y despliegue.", priorUserRequests: [])
        var rounds: [AssistantResearchRound] = []
        _ = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { round in
            rounds.append(round)
            return ""
        }
        let initial = rounds.filter { $0.purpose != .repair }
        #expect(initial.count == 1)
        #expect(initial.first?.maximumTokens == 4_096)
        #expect(initial.first?.request.contains("## Frontend") == true)
        #expect(initial.first?.request.contains("## Despliegue") == true)
    }

    @Test("El presupuesto conserva el prompt y sus evidencias antes del veredicto")
    func boundsOneShotBeforeEvidenceEviction() {
        #expect(AssistantSessionPolicy.generationLimit(requestedTokens: 8192, promptTokens: 4000, contextTokens: 8192) == 4160)
        #expect(AssistantSessionPolicy.generationLimit(requestedTokens: 8192, promptTokens: 8200, contextTokens: 8192) == nil)
        #expect(AssistantSessionPolicy.generationLimit(requestedTokens: 8192, promptTokens: 7800, contextTokens: 8192) == nil)
        #expect(AssistantSessionPolicy.generationLimit(requestedTokens: 256, promptTokens: 7800, contextTokens: 8192) == 256)
        #expect(AssistantSessionPolicy.generationLimit(requestedTokens: 2048, promptTokens: 4000, contextTokens: 16384) == 2048)
    }

    @Test("La respuesta directa respeta pensamiento e identidad exacta del modelo")
    func directSessionModelAndThinkingGates() {
        #expect(AssistantSessionPolicy.directResponsePrefix(modelID: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit", directoryName: "LFM2.5-8B-A1B-MLX-8bit", thinking: false) == "<think></think>\n")
        #expect(AssistantSessionPolicy.directResponsePrefix(modelID: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit", directoryName: "LFM2.5-8B-A1B-MLX-8bit", thinking: true) == nil)
        #expect(AssistantSessionPolicy.directResponsePrefix(modelID: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit", directoryName: "otra-revisión", thinking: false) == nil)
        #expect(AssistantSessionPolicy.directResponsePrefix(modelID: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit", directoryName: "LFM2.5-8B-A1B-MLX-4bit", thinking: false) == nil)
        #expect(AssistantSessionPolicy.directResponsePrefix(modelID: "Otra/Identidad", directoryName: "LFM2.5-8B-A1B-MLX-8bit", thinking: false) == nil)
    }

    @Test("El límite real usa el conteo de tokens aunque el SDK informe cancelación")
    func detectsRealTokenLimit() {
        #expect(AssistantSessionPolicy.reachedTokenLimit(generatedTokens: 597, maximumTokens: 597, stopWasLength: false))
        #expect(AssistantSessionPolicy.reachedTokenLimit(generatedTokens: 30, maximumTokens: 597, stopWasLength: true))
        #expect(!AssistantSessionPolicy.reachedTokenLimit(generatedTokens: 30, maximumTokens: 597, stopWasLength: false))
        #expect(!AssistantSessionPolicy.reachedTokenLimit(generatedTokens: 0, maximumTokens: 0, stopWasLength: false))
    }

    private func backendDossier() -> AssistantResearchDossier {
        var dossier = AssistantResearchDossier()
        let sources: [AssistantResearchSource] = [
            .init(title: "FastAPI", url: "https://fastapi.tiangolo.com/", bookmarkID: UUID(), summary: "FastAPI es un framework backend para implementar API.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: []),
            .init(title: "Supabase", url: "https://supabase.com/", bookmarkID: UUID(), summary: "Supabase ofrece backend, usuarios y API con una base de datos PostgreSQL.", evidence: "", origin: .library, facets: [.engine, .database], collection: nil, tags: []),
        ]
        dossier.append(.init(sources: sources, candidateCount: 2), query: .init(facet: .engine, text: "backend"), web: false)
        return dossier
    }

    @Test("Los metadatos públicos reales de 0514 se separan por responsabilidad y mantienen procedencia e IDs")
    @MainActor
    func separatesRealPublicMetadataByRole() async throws {
        // Extractos públicos del deck persistido de 0514; los IDs pertenecen a este
        // dossier de prueba, pues el historial no conserva el dossier del prompt.
        let records: [(String, String, String, AssistantLinkReference.Origin)] = [
            ("Deploy any project in seconds, in our cloud or yours.", "https://northflank.com/", "Northflank es una plataforma de desarrolladores que permite desplegar cualquier proyecto rápidamente, ya sea en la nube de Northflank o en la suya. Ofrece un entorno basado en contenedores y Kubernetes, facilitando la gestión de servicios, bases de datos, trabajos por lotería y agentes.", .library),
            ("SQLite Serverless", "https://turso.tech/", "SQLite Serverless es una base de datos ligera basada en SQLite, diseñada para aplicaciones modernas que requieren escalabilidad y rendimiento. Permite crear una base de datos por cada usuario, agente o teniente, eliminando la necesidad de un proceso compartido y ofreciendo acceso siempre disponible sin reinicios.", .library),
            ("Elasticsearch: el motor oficial de búsqueda y analíticas distribuido ...", "https://www.elastic.co/es/elasticsearch", "Elasticsearch es un motor de búsqueda y analíticas distribuido open source desarrollado para aplicaciones de velocidad, escalabilidad y AI.", .web),
            ("PocketBase - Open Source backend in 1 file", "https://pocketbase.io/", "PocketBase es un backend de código abierto que se instala en a lo sumo un archivo y proporciona una base de datos en tiempo real, autenticación, almacenamiento de archivos y panel de administración.", .library),
        ]
        var dossier = AssistantResearchDossier()
        for (title, url, summary, origin) in records {
            let source = AssistantResearchSource(title: title, url: url, bookmarkID: nil, summary: summary, evidence: "", origin: origin,
                facets: Set(AssistantResearchFacet.allCases.filter { $0.matches(title + " " + summary) }), collection: nil, tags: [])
            dossier.append(.init(sources: [source], candidateCount: 1), query: .init(facet: .overview, text: "software"), web: origin == .web)
        }
        let originalIDs = Dictionary(uniqueKeysWithValues: dossier.indexedSources.map { ($0.source.url!, $0.id) })
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app: backend, base de datos, búsqueda, almacenamiento y despliegue.", priorUserRequests: [])
        _ = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4_096) { round in
            if round.purpose == .composition {
                func role(_ title: String) -> String {
                    String(round.request.components(separatedBy: "## " + title + "\n")[1].components(separatedBy: "\n\n##")[0])
                }
                #expect(round.sourceAliasesByRole["engine"]?.values.contains(originalIDs["https://northflank.com/"]!) == false)
                #expect(round.sourceAliasesByRole["engine"]?.values.contains(originalIDs["https://pocketbase.io/"]!) == true)
                #expect(round.sourceAliasesByRole["storage"]?.values.contains(originalIDs["https://turso.tech/"]!) == false)
                #expect(role("Almacenamiento").contains("archivos, recursos binarios y objetos"))
                #expect(round.sourceAliasesByRole["search"]?.values.contains(originalIDs["https://www.elastic.co/es/elasticsearch"]!) == true)
                #expect(round.request.contains("Web; metadatos o resultado; no verificado"))
            }
            return "• Elección y encaje: propuesta provisional sin respaldo de fuentes; falta confirmar el volumen.\n• Alternativa: alternativa provisional sin respaldo de fuentes; falta confirmar si se requiere operación local.\n• Límite pendiente: comprobar los permisos y el volumen."
        }
    }

    @Test("Una reparación dirigida conserva las decisiones válidas y no da al LLM un borrador como turno assistant")
    @MainActor
    func repairsOnlyInvalidSections() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero desarrollar una app: backend y base de datos.", priorUserRequests: [])
        var rounds: [AssistantResearchRound] = []
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { round in
            rounds.append(round)
            switch round.purpose {
            case .composition:
                return structured([component("engine", choice: "B1", alternative: "B2", fit: "«Northflank» implementa las cuentas del programa.", difference: "Incluye usuarios y API para reducir el desarrollo inicial."),
                                   component("database", choice: "B2", fit: "Conserva los registros en PostgreSQL.")],
                                  integration: "Conecta la interfaz con la API del backend elegido. Verifica las políticas de acceso antes de publicar.")
            case .repair:
                #expect(!round.request.contains("«Northflank» implementa las cuentas"))
                #expect(round.request.contains("decisiones aceptadas; consérvalas"))
                #expect(!round.request.contains("## Base de datos\n##"))
                return structured([component("engine", choice: "B1", alternative: "B2", fit: "Implementa la API del programa.", difference: "Incluye usuarios y API para reducir el desarrollo inicial.")],
                                  integration: "Conecta el frontend con la API del backend. Mantén una única base de datos y verifica las políticas de acceso.")
            }
        }
        #expect(rounds.map(\.maximumTokens).reduce(0, +) <= 8_192)
        #expect(rounds.filter { $0.purpose == .repair }.count == 1)
        #expect(result.text.contains("«FastAPI» — Implementa"))
        #expect(result.text.contains("«Supabase» — Conserva los registros en PostgreSQL. [B2]"))
        #expect(!result.text.contains("Northflank"))
        #expect(result.issues.isEmpty)
    }

    @Test("Una reparación fallida no fabrica citas ni acepta una atribución falsa")
    @MainActor
    func failedRepairKeepsUnresolvedStatus() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        var repairs = 0
        let result = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { round in
            if round.purpose == .repair { repairs += 1 }
            return structured([component("engine", choice: "W999", alternative: "B2", fit: "«Northflank» gestiona los usuarios del programa.", difference: "Incluye usuarios y API para reducir el desarrollo inicial.")])
        }
        #expect(repairs == 1)
        #expect(!result.issues.isEmpty)
        #expect(!result.text.contains("[W999]"))
        #expect(result.text.contains("No he podido respaldar"))
        #expect(Set(result.sources.keys) == ["B1", "B2"])
    }

    @Test("Una continuación centrada en backend conserva los requisitos y no vuelve a generar seis papeles")
    @MainActor
    func focusesFollowUpWithoutLosingRequirements() async throws {
        let plan = AssistantResearchPlan.make(request: "En ese caso compara el backend.", priorUserRequests: ["Quiero desarrollar una app sin conexión: frontend, backend, base de datos, búsqueda, almacenamiento y despliegue."])
        var initialRequests: [String] = []
        _ = try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { round in
            if round.purpose == .composition { initialRequests.append(round.request) }
            #expect(round.request.contains("sin conexión"))
            return structured([component("engine", choice: "B1", alternative: "B2", fit: "Implementa la API del programa.", difference: "Incluye usuarios y API para reducir el desarrollo inicial.", verification: "Comprobar si la operación local satisface el requisito sin conexión.")])
        }
        #expect(initialRequests.count == 1)
        #expect(initialRequests[0].contains("## Backend"))
        #expect(!initialRequests[0].contains("## Frontend"))
    }

    @Test("Cancelar una composición detiene las rondas siguientes antes de generar o reparar")
    @MainActor
    func cancelsBeforeNextComponent() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app: frontend, backend y base de datos.", priorUserRequests: [])
        var calls = 0
        let task = Task { @MainActor in
            try await composeFixture(plan: plan, dossier: backendDossier(), spanish: true, outputTokens: 4_096) { _ in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return "No debe continuar."
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(calls == 1)
    }

    @Test("Una composición comparte las fuentes de los seis papeles sin repetir sus metadatos")
    @MainActor
    func focusedCompositionBudgetAndRoles() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero desarrollar un marketplace de recursos digitales: frontend, backend, base de datos, búsqueda, almacenamiento y despliegue.", priorUserRequests: [])
        var dossier = AssistantResearchDossier()
        let source = AssistantResearchSource(title: "Fuente de prueba", url: "https://example.org/docs", bookmarkID: nil,
            summary: "Frontend backend base de datos SQL búsqueda almacenamiento archivos deployment hosting", evidence: "", origin: .web,
            facets: Set(plan.requestedFacets), collection: nil, tags: [])
        dossier.append(.init(sources: [source], candidateCount: 1), query: .init(facet: .overview, text: "software"), web: true)
        var rounds: [AssistantResearchRound] = []
        _ = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4_096) { round in
            rounds.append(round)
            return structured(["interface", "engine", "database", "search", "storage", "deployment"].map {
                component($0, choice: nil)
            }, integration: "Verifica los permisos de acceso antes de publicar.")
        }
        let initial = rounds.filter { $0.purpose == .composition }
        #expect(initial.count == 1)
        #expect(initial[0].maximumTokens == 4_096)
        #expect(rounds.filter { $0.purpose == .repair }.count <= 1)
        #expect(initial[0].instructions.contains("español"))
        #expect(initial[0].request.contains("Almacenamiento"))
        #expect(initial[0].request.contains("archivos"))
        #expect(initial[0].request.components(separatedBy: "Fuente: Fuente de prueba").count == 2)

    }

    @Test("El objetivo se separa de las instrucciones y conserva los componentes pedidos")
    func conciseQueriesForRequestedComponents() {
        let plan = AssistantResearchPlan.make(request: "Quiero desarrollar un marketplace de recursos digitales. Revisa toda mi biblioteca y completa con fuentes públicas en internet: frontend, backend, base de datos, búsqueda, almacenamiento y despliegue. Relaciona cada recomendación con sus fuentes reales y señala lo que falta verificar. No modifiques enlaces ni colecciones.", priorUserRequests: [])
        #expect(plan.publicTopic.contains("marketplace"))
        #expect(plan.publicTopic.contains("recursos"))
        #expect(!plan.publicTopic.lowercased().contains("revisa"))
        #expect(!plan.publicTopic.lowercased().contains("relaciona"))
        #expect(plan.publicTopic.count < 90)
        let roles = Set(plan.libraryQueries.map { $0.facet.rawValue })
        #expect(roles.contains("database"))
        #expect(roles.contains("search"))
        #expect(roles.contains("deployment"))
        #expect(plan.libraryQueries.count <= 6)
        #expect(plan.webQueries(coveredFacets: []).count <= 4)
    }

    @Test("Los metadatos candidatos no sustituyen la contrastación pública")
    func metadataDoesNotVerifyComponents() {
        var dossier = AssistantResearchDossier()
        for (index, facet) in AssistantResearchFacet.allCases.enumerated() {
            let source = AssistantResearchSource(title: "Candidato \(index)", url: "https://example.org/\(index)", bookmarkID: UUID(),
                summary: "Metadatos de una herramienta", evidence: "", origin: .library,
                facets: [facet], collection: nil, tags: [])
            dossier.append(.init(sources: [source], candidateCount: 1), query: .init(facet: facet, text: facet.title), web: false)
        }
        #expect(dossier.coveredFacets.isEmpty)
        let plan = AssistantResearchPlan.make(request: "Quiero desarrollar una app de mapas", priorUserRequests: [])
        #expect(plan.webQueries(coveredFacets: dossier.coveredFacets).count == 4)
    }

    @Test("Un PDF sobre derechos del consumidor no se lee como documentación de software")
    @MainActor
    func ignoresUnrelatedWebCandidate() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una plataforma de mapas", priorUserRequests: [])
        let legal = AssistantResearchSource(title: "Derechos del consumidor", url: "https://consumer.example.org/derechos.pdf", bookmarkID: nil,
            summary: "Reclamaciones sobre compras y devoluciones", evidence: "", origin: .web,
            facets: [.overview], collection: nil, tags: [])
        let technical = AssistantResearchSource(title: "API de mapas", url: "https://docs.example.org/maps", bookmarkID: nil,
            summary: "Documentación del backend, API e integración para aplicaciones de mapas", evidence: "", origin: .web,
            facets: [.engine], collection: nil, tags: [])
        var pages: [String] = []
        _ = try await AssistantResearchCoordinator.collect(plan: plan, webEnabled: true,
            librarySearch: { _ in .init(sources: [], candidateCount: 0) },
            webSearch: { _ in .init(sources: [legal, technical], candidateCount: 2) },
            readPage: { url in pages.append(url); return .init(title: "API de mapas", url: url, text: "API y backend de mapas") },
            progress: { _ in })
        #expect(!pages.contains(legal.url!))
        #expect(pages.contains(technical.url!))
    }

    @Test("La respuesta real mixta exige español y rechaza los marcadores de cita incompletos")
    func validatesObservedMixedLanguageAnswer() {
        let source = AssistantResearchSource(title: "Entorno de desarrollo", url: "https://example.org/ide", bookmarkID: nil,
            summary: "IDE que permite generar y editar código", evidence: "", origin: .library,
            facets: [.overview], collection: nil, tags: [])
        let observed = """
        Propongo una pila tecnológica basada en fuentes públicas verificadas.
        • Interfaz – Firebase Studio (B7) provides a full-stack environment for building responsive interfaces and APIs. [B7]/[W...]
        • Motor – Supabase offers serverless functions and real-time API for business logic. [B5]/[W...]
        • Almacenamiento – PocketBase is a single-file SQLite-based backend with authentication and file storage. [B20]/[W...]
        F f falta verificar la documentación específica.
        """
        let issues = AssistantResearchAnswer.issues(in: observed, spanish: true, sources: ["B7": source])
        #expect(issues.contains { $0.contains("inglés") })
        #expect(issues.contains { $0.contains("W...") })
        #expect(issues.contains { $0.contains("Interfaz") })
        #expect(issues.contains { $0.contains("fragmentos sueltos") })
        #expect(issues.contains { $0.contains("fuentes verificadas") })
        let displayed = AssistantResearchAnswer.resolvedText(observed, sources: ["B7": source])
        #expect(displayed.contains("[B7]"))
        #expect(!displayed.contains("[W...]") && !displayed.contains("[B20]") && !displayed.contains("(B7)"))
    }

    @Test("La detección del idioma reconoce explicación inglesa sin palabras del vocabulario auxiliar")
    func validatesEnglishWithoutCommonConnectors() {
        let source = AssistantResearchSource(title: "Supabase", url: "https://example.org/backend", bookmarkID: nil,
            summary: "Backend con autenticación y API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let observed = "Backend: Supabase handles authentication securely, persists user records, exposes REST endpoints [B1]."
        let issues = AssistantResearchAnswer.issues(in: observed, spanish: true, sources: ["B1": source], detectedLanguage: { _ in "en" })
        #expect(issues.contains { $0.contains("inglés") })
        let translated = "Backend: Supabase gestiona la autenticación, guarda usuarios y ofrece una API; verifica sus límites antes de integrarlo [B1]."
        #expect(AssistantResearchAnswer.issues(in: translated, spanish: true, sources: ["B1": source], detectedLanguage: { _ in "es" }).isEmpty)
    }

    @Test("Las recomendaciones sin citas requieren relacionar fuentes o declarar el hueco")
    func requiresSourcesForUncitedProposal() {
        let source = AssistantResearchSource(title: "API de usuarios", url: "https://example.org/users", bookmarkID: nil,
            summary: "Backend con autenticación y API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        let observed = "Backend: utiliza Supabase para usuarios y pagos. Base de datos: PostgreSQL."
        #expect(AssistantResearchAnswer.issues(in: observed, spanish: true, sources: sources).contains { $0.contains("fuentes") })
        let provisional = "Backend: propuesta provisional de Supabase para usuarios y pagos; falta verificar su respaldo con fuentes."
        #expect(AssistantResearchAnswer.issues(in: provisional, spanish: true, sources: sources).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "Gracias. ¿Qué requisitos faltan por aclarar?", spanish: true, sources: sources).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "¿Qué backend necesitas?", spanish: true, sources: sources).isEmpty)
    }

    @Test("Las citas resuelven exactamente a fuentes presentes en el contexto acotado")
    func resolvesActualCitationMap() {
        var dossier = AssistantResearchDossier()
        let source = AssistantResearchSource(title: "API de audio", url: "https://example.org/audio", bookmarkID: nil,
            summary: "Backend de procesamiento de audio", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        dossier.append(.init(sources: [source], candidateCount: 1), query: .init(facet: .engine, text: "audio"), web: false)
        let context = dossier.context(maximumCharacters: 2_000)
        let citations = dossier.citationSources(in: context)
        #expect(citations["B1"]?.url == source.url)
        #expect(dossier.citationSources(in: "").isEmpty)
        let valid = "Motor: usa «API de audio» para el procesamiento del audio y verifica sus límites antes de integrarlo [B1]."
        #expect(AssistantResearchAnswer.issues(in: valid, spanish: true, sources: citations).isEmpty)
        #expect(AssistantResearchAnswer.resolvedText(valid, sources: citations).contains("«API de audio»"))
        #expect(AssistantResearchAnswer.issues(in: "Usa esta API [B999].", spanish: true, sources: citations).contains { $0.contains("B999") })
    }

    @Test("La presentación conserva las citas válidas en la respuesta final")
    func preservesVisibleVerifiedCitations() {
        let source = AssistantResearchSource(title: "API de audio", url: "https://example.org/audio", bookmarkID: nil,
            summary: "Backend de procesamiento de audio", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let displayed = AssistantResearchAnswer.resolvedText("Motor: usa «API de audio» [B1]. Alternativa (B1).", sources: ["B1": source])
        #expect(AssistantResearchAnswer.citationTokens(in: displayed) == ["B1", "B1"])
        #expect(!displayed.contains("(B1)"))
    }

    @Test("Una cita en frontend y una advertencia global no respaldan las demás recomendaciones")
    func validatesEachProposalRatherThanGlobalDisclaimer() {
        let source = AssistantResearchSource(title: "Toolkit", url: "https://example.org/ui", bookmarkID: nil,
            summary: "Componentes visuales para una interfaz frontend", evidence: "", origin: .library,
            facets: [.interface], collection: nil, tags: [])
        let observed = """
        Frontend: usa Toolkit [B1].
        Backend
        • Recomendación: emplear Supabase para usuarios. Falta verificar sus permisos.
        Almacenamiento
        • Recomendación: considerar PocketBase para archivos. Falta verificar los límites.
        Falta verificar el stack antes de implementarlo.
        """
        #expect(AssistantResearchAnswer.issues(in: observed, spanish: true, sources: ["B1": source]).contains { $0.contains("fuentes") })
        let sameParagraph = "Frontend: usa Toolkit [B1]. Backend: usa Toolkit para usuarios; falta verificar los permisos."
        #expect(AssistantResearchAnswer.issues(in: sameParagraph, spanish: true, sources: ["B1": source]).contains { $0.contains("fuentes") })
        let unsupported = "Backend: opción provisional sin respaldo de fuentes; no hay evidencia para recomendar una tecnología concreta."
        #expect(AssistantResearchAnswer.issues(in: unsupported, spanish: true, sources: ["B1": source]).isEmpty)
    }

    @Test("La cita no permite cambiar el nombre de la tecnología ni asignar un papel ajeno")
    func rejectsSourceIdentityAndRoleSubstitution() {
        let sqlite = AssistantResearchSource(title: "SQLite Serverless", url: "https://example.org/sqlite", bookmarkID: nil,
            summary: "Base de datos SQLite serverless", evidence: "", origin: .library,
            facets: [.database], collection: nil, tags: [])
        let ui = AssistantResearchSource(title: "Tailwind CSS UI Kit", url: "https://example.org/ui", bookmarkID: nil,
            summary: "Kit de componentes visuales para frontend", evidence: "", origin: .library,
            facets: [.interface], collection: nil, tags: [])
        let sources = ["B1": sqlite, "B2": ui]
        let observed = """
        Backend
        • Recomendación: emplear Supabase [B1] como backend.
        Exportación e integración
        • Recomendación: utilizar Tailwind CSS UI Kit [B2] para exportar archivos.
        """
        let issues = AssistantResearchAnswer.issues(in: observed, spanish: true, sources: sources)
        #expect(issues.contains { $0.contains("Supabase") && $0.contains("B1") })
        #expect(issues.contains { $0.contains("Integración") && $0.contains("B2") })
        #expect(AssistantResearchAnswer.issues(in: "Base de datos: utiliza «SQLite Serverless» [B1] como candidato; verifica sus límites.", spanish: true, sources: sources).isEmpty)
    }

    @Test("Los seis componentes explícitos se conservan separados y en el orden pedido")
    func preservesExplicitRolesInAnswer() {
        let plan = AssistantResearchPlan.make(request: "Quiero desarrollar una herramienta: frontend, backend, base de datos, búsqueda, almacenamiento y despliegue.", priorUserRequests: [])
        #expect(plan.requestedFacets.map { plan.componentTitle(for: $0) } == ["Frontend", "Backend", "Base de datos", "Búsqueda", "Almacenamiento", "Despliegue"])
        let observed = """
        Interfaz: elección provisional sin respaldo de fuentes.
        Motor: elección provisional sin respaldo de fuentes.
        Almacenamiento: elección provisional sin respaldo de fuentes.
        Exportación e integración: elección provisional sin respaldo de fuentes.
        Validación y distribución: elección provisional sin respaldo de fuentes.
        Falta verificar la base de datos.
        """
        let issues = AssistantResearchAnswer.issues(in: observed, spanish: true, sources: [:], requiredFacets: plan.requestedFacets)
        #expect(issues.contains { $0.contains("Base de datos") })
        #expect(issues.contains { $0.contains("Búsqueda") })
        let complete = """
        Frontend: elección provisional sin respaldo de fuentes.
        Backend: elección provisional sin respaldo de fuentes.
        Base de datos: elección provisional sin respaldo de fuentes.
        Búsqueda: elección provisional sin respaldo de fuentes.
        Almacenamiento: elección provisional sin respaldo de fuentes.
        Despliegue: elección provisional sin respaldo de fuentes.
        """
        #expect(AssistantResearchAnswer.issues(in: complete, spanish: true, sources: [:], requiredFacets: plan.requestedFacets).isEmpty)
    }

    @Test("Los verbos de recomendación y encabezados sin contenido no son tecnologías ni propuestas sin citar")
    func acceptsRecommendationVerbAndPureHeading() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        #expect(AssistantResearchAnswer.issues(in: "Backend: Recomiendo FastAPI [B1].", spanish: true, sources: sources).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "## Backend:\n• Usa «FastAPI» para la API [B1].", spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "Backend: Recomiendo OtraTecnología [B1].", spanish: true, sources: sources).contains { $0.contains("OtraTecnología") })
    }

    @Test("Sin fuentes las elecciones firmes requieren declarar su falta de respaldo y carácter provisional")
    func rejectsFirmChoicesWhenNoSourcesWereRetrieved() {
        let roles: [AssistantResearchFacet] = [.interface, .engine, .database, .search, .storage, .deployment]
        let observed = """
        Frontend: usa React.
        Backend: utiliza Supabase.
        Base de datos: PostgreSQL.
        Búsqueda: Elasticsearch.
        Almacenamiento: S3.
        Despliegue: Vercel.
        """
        #expect(AssistantResearchAnswer.issues(in: observed, spanish: true, sources: [:], requiredFacets: roles).contains { $0.contains("respaldo") })
        #expect(AssistantResearchAnswer.issues(in: "Backend: utiliza Supabase; elección provisional sin respaldo de fuentes.", spanish: true, sources: [:], requiredFacets: [.engine]).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "Backend: utiliza Supabase; falta verificar los permisos.", spanish: true, sources: [:], requiredFacets: [.engine]).contains { $0.contains("respaldo") })
        #expect(AssistantResearchAnswer.issues(in: "Gracias. ¿Qué backend necesitas?", spanish: true, sources: [:]).isEmpty)
    }

    @Test("Una oración o viñeta con un componente no es un encabezado vacío")
    func distinguishesProseFromPureComponentHeading() {
        for text in ["• Usa Supabase como backend", "• Backend utiliza Supabase", "Backend utiliza Supabase."] {
            let issues = AssistantResearchAnswer.issues(in: text, spanish: true, sources: [:], requiredFacets: [.engine])
            #expect(issues.contains { $0.contains("respaldo") })
            #expect(issues.contains { $0.contains("Faltan componentes") })
        }
        let provisional = "## **Backend:**\n• Usa Supabase como elección provisional sin respaldo de fuentes"
        #expect(AssistantResearchAnswer.issues(in: provisional, spanish: true, sources: [:], requiredFacets: [.engine]).isEmpty)
    }

    @Test("Los rótulos estructurales conservan los seis componentes en español e inglés")
    func acceptsStructuralComponentLabels() {
        let roles: [AssistantResearchFacet] = [.interface, .engine, .database, .search, .storage, .deployment]
        for headings in [
            ["## Frontend:", "**Backend:**", "### Base de datos", "• Búsqueda:", "Almacenamiento", "Despliegue:"],
            ["## Interface:", "**Back-end:**", "### Database", "• Search:", "Storage", "Deployment:"]
        ] {
            let text = headings.map { $0 + "\n• Elección provisional sin respaldo de fuentes." }.joined(separator: "\n")
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: [:], requiredFacets: roles).isEmpty)
        }
    }

    @Test("La prosa tras dos puntos no introduce nombres de producto por su inicial mayúscula")
    func extractsProductsWithoutTreatingModalProseAsNames() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        for text in ["Backend: Puedes utilizar FastAPI[B1].", "Backend: I recommend FastAPI[B1].", "Backend: FastAPI[B1]."] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).isEmpty)
        }
        #expect(AssistantResearchAnswer.issues(in: "Backend: Puedes utilizar OtraTecnología[B1].", spanish: true, sources: sources).contains { $0.contains("OtraTecnología") })
        #expect(AssistantResearchAnswer.issues(in: "Backend: Supabase[B1].", spanish: true, sources: sources).contains { $0.contains("Supabase") })
    }

    @Test("Un producto con explicación tras el rótulo debe aparecer en la fuente citada")
    func validatesProductIdentityBeforePurposeExplanation() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        for text in ["Backend: Supabase para usuarios y API [B1].", "Backend: Supabase como servidor de API [B1]."] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).contains { $0.contains("Supabase") })
        }
        for text in ["Backend: FastAPI para usuarios y API [B1].", "Backend: FastAPI como servidor de API [B1].", "Backend: Puedes utilizar FastAPI para usuarios y API [B1]."] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).isEmpty)
        }
        #expect(AssistantResearchAnswer.issues(in: "Backend: I recommend FastAPI for user accounts and API [B1].", spanish: false, sources: sources).isEmpty)
    }

    @Test("La identidad tras el componente se valida también antes de prosa libre")
    func validatesProductIdentityBeforeFreeProse() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        #expect(AssistantResearchAnswer.issues(in: "Backend: Supabase gestiona usuarios mediante una API [B1].", spanish: true, sources: sources).contains { $0.contains("Supabase") })
        #expect(AssistantResearchAnswer.issues(in: "Backend: FastAPI gestiona usuarios mediante una API [B1].", spanish: true, sources: sources).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "Backend: OtraTecnología gestiona usuarios mediante una API [B1].", spanish: true, sources: sources).contains { $0.contains("OtraTecnología") })
    }

    @Test("Una introducción gramatical no se convierte en producto pero conserva la identidad posterior")
    func distinguishesGrammaticalIntroductionFromProductIdentity() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        #expect(AssistantResearchAnswer.issues(in: "Backend: Recomendado para usuarios y API: FastAPI [B1].", spanish: true, sources: sources).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: "Backend: Recomendado para usuarios y API: Supabase [B1].", spanish: true, sources: sources).contains { $0.contains("Supabase") })
    }

    @Test("Las introducciones nominales y el énfasis no se convierten en nombres de producto")
    func acceptsCommonNounIntroductionsAndUppercaseEmphasis() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        for text in ["Backend: Arquitectura basada en FastAPI [B1].", "Backend: Servicio construido con FastAPI [B1].", "Backend: RECOMIENDO FastAPI [B1]."] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).isEmpty)
        }
        for text in ["Backend: Arquitectura basada en Supabase [B1].", "Backend: Servicio construido con Supabase [B1].", "Backend: RECOMIENDO Supabase [B1]."] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).contains { $0.contains("Supabase") })
        }
    }

    @Test("Los lemas comunes no eliminan marcas ni permiten asignarles otra fuente")
    func preservesBrandsEvenWhenTheirSpellingIsACommonWord() {
        let fastAPI = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        for name in ["Astro", "Firebase"] {
            let source = AssistantResearchSource(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                summary: "Backend con módulos de API", evidence: "", origin: .library,
                facets: [.engine], collection: nil, tags: [])
            for text in ["Backend: \(name) gestiona usuarios mediante una API [B1].", "Backend: \(name) basado en módulos de API [B1].", "Backend: «\(name)» basado en módulos de API [B1]."] {
                #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": source]).isEmpty)
                #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": fastAPI]).contains { $0.contains(name) })
            }
        }
    }

    @Test("Una introducción común conserva todas las identidades posteriores sin límite silencioso de palabras")
    func validatesEveryIdentityAfterCommonIntroduction() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": source]
        for text in [
            "Backend: Arquitectura basada en una API con Supabase [B1].",
            "Backend: Arquitectura basada en una API para usuarios con acceso controlado, registros privados y permisos configurables mediante Supabase [B1].",
            "Backend: Arquitectura basada en FastAPI con «Supabase» para usuarios [B1].",
            "Backend: FastAPI con Supabase para usuarios [B1]."
        ] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).contains { $0.contains("Supabase") })
        }
        for text in [
            "Backend: Arquitectura basada en una API con FastAPI [B1].",
            "Backend: Arquitectura basada en una API para usuarios con acceso controlado, registros privados y permisos configurables mediante FastAPI [B1]."
        ] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: sources).isEmpty)
        }
    }

    @Test("Las plataformas con inicial minúscula se contrastan como tokens completos")
    func validatesWholeLowercaseInitialPlatformNames() {
        let compatible = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API compatible con macOS e iOS", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let unsupported = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        for platform in ["macOS", "iOS"] {
            let text = "Backend: FastAPI funciona en \(platform) [B1]."
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": compatible]).isEmpty)
            let issues = AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": unsupported])
            #expect(issues.contains { $0.contains("«\(platform)»") })
            #expect(!issues.contains { $0.contains("«OS»") })
        }
    }

    @Test("La identidad técnica conserva el prefijo y el sufijo al contrastar una fuente")
    func preservesFullTechnicalTokenIdentity() {
        let fastAPI = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        for name in ["prefixFastAPI", "FastAPISuffix", "p3FastAPI", "prefix.FastAPI", "prefix_FastAPI", "prefix-FastAPI"] {
            let source = AssistantResearchSource(title: name, url: "https://example.org/identity", bookmarkID: nil,
                summary: "Framework backend para crear una API", evidence: "", origin: .library,
                facets: [.engine], collection: nil, tags: [])
            let text = "Backend: \(name) gestiona usuarios mediante una API [B1]."
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": source]).isEmpty)
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": fastAPI]).contains { $0.contains("«\(name)»") })
        }
    }

    @Test("Las cantidades y los ordinales numéricos no se convierten en productos")
    func excludesPurelyNumericQuantitiesFromProducts() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        for text in [
            "Backend: Recomiendo FastAPI; revisa 2 alternativas antes de elegir [B1].",
            "Backend: FastAPI es mi opción 1 [B1].",
            "Backend: FastAPI es mi primera opción [B1]."
        ] {
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": source]).isEmpty)
        }
    }

    @Test("Excluir cantidades conserva los identificadores técnicos y las versiones con cifras")
    func preservesTechnicalNamesAndVersionsWithDigits() {
        let fastAPI = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        for name in ["p3FastAPI", "3D", "Python3.14", "FastAPI2"] {
            let source = AssistantResearchSource(title: name, url: "https://example.org/identity", bookmarkID: nil,
                summary: "Framework backend para crear una API", evidence: "", origin: .library,
                facets: [.engine], collection: nil, tags: [])
            let text = "Backend: \(name) gestiona usuarios mediante una API [B1]."
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": source]).isEmpty)
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": fastAPI]).contains { $0.contains("«\(name)»") })
        }
        let versioned = AssistantResearchSource(title: "FastAPI 0.115.0", url: "https://example.org/version", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        #expect(AssistantResearchAnswer.issues(in: "Backend: FastAPI 0.115.0 para una API [B1].", spanish: true, sources: ["B1": versioned]).isEmpty)
    }

    @Test("La respuesta real de 0409 conserva los seis apartados y detecta la búsqueda sin cita")
    func separatesObservedSingleParagraphComponents() {
        let observed = "Frontend: Tailwind CSS UI Kit es un kit de componentes de interfaz de usuario basado en Tailwind CSS que brinda una integración fluida y una personalización total. [B14] Backend: PocketBase es un backend de código abierto que se instala en a lo sumo un archivo y proporciona una base de datos en tiempo real, autenticación, almacenamiento de archivos y panel de administración. [B22] Base de datos: SQLite Serverless es una base de datos ligera basada en SQLite, diseñada para aplicaciones modernas que requieren escalabilidad y rendimiento. [B6] Búsqueda: Elasticsearch es un motor de búsqueda y analíticas distribuido open source desarrollado para aplicaciones de velocidad, escalabilidad y AI. Almacenamiento: PocketBase es un backend de código abierto que se instala en a lo sumo un archivo y proporciona una base de datos en tiempo real, autenticación, almacenamiento de archivos y panel de administración. [B22] Despliegue: Northflank es una plataforma de desarrolladores que permite desplegar cualquier proyecto rápidamente, ya sea en la nube de Northflank o en la suya. [B10]"
        func source(_ title: String, _ summary: String, _ facets: Set<AssistantResearchFacet>) -> AssistantResearchSource {
            .init(title: title, url: "https://example.org/" + title.replacingOccurrences(of: " ", with: "-"), bookmarkID: nil,
                  summary: summary, evidence: "", origin: .library, facets: facets, collection: nil, tags: [])
        }
        let sources = [
            "B14": source("Tailwind CSS UI Kit", "Componentes de interfaz basados en Tailwind CSS", [.interface]),
            "B22": source("PocketBase", "Backend con autenticación, base de datos y almacenamiento de archivos", [.engine, .database, .storage]),
            "B6": source("SQLite Serverless", "Base de datos SQLite para aplicaciones", [.database]),
            "B10": source("Northflank", "Plataforma para desplegar proyectos", [.deployment])
        ]
        let roles: [AssistantResearchFacet] = [.interface, .engine, .database, .search, .storage, .deployment]
        let issues = AssistantResearchAnswer.issues(in: observed, spanish: true, sources: sources, requiredFacets: roles)
        #expect(!issues.contains { $0.contains("Faltan componentes") })
        #expect(!issues.contains { $0.contains("B22") && $0.contains("papel «Interfaz»") })
        #expect(!issues.contains { $0.contains("B10") && $0.contains("papel «Almacenamiento»") })
        #expect(issues.contains { $0.contains("Búsqueda") && $0.contains("fuentes") })
        let displayed = AssistantResearchAnswer.resolvedText(observed, sources: sources)
        let headings = AssistantResponsePresentation.blocks(from: displayed).filter { $0.kind == .heading }.map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
        #expect(headings == ["Frontend", "Backend", "Base de datos", "Búsqueda", "Almacenamiento", "Despliegue"])
        #expect(AssistantResearchAnswer.citationTokens(in: displayed) == ["B14", "B22", "B6", "B22", "B10"])
        #expect(displayed.replacingOccurrences(of: "#", with: "").split(whereSeparator: \.isWhitespace).map(String.init) == observed.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    @Test("La cita después del punto pertenece a la elección anterior y no respalda una alternativa siguiente")
    func associatesTrailingCitationsWithTheirStatement() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let observed = "Backend: usa FastAPI. [B1] Alternativa: usa Supabase."
        #expect(AssistantResearchAnswer.issues(in: observed, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).contains { $0.contains("respaldo") })
    }

    @Test("Una coma o barra entre citas no respalda una alternativa posterior sin su propia cita")
    func associatesDelimitedTrailingCitationGroupsWithTheirStatement() {
        func source(_ name: String) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API", evidence: "", origin: .library,
                  facets: [.engine], collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI"), "B2": source("Supabase")]
        for separator in [", ", "/", " "] {
            let observed = "Backend: usa «FastAPI». [B1]\(separator)[B2] Alternativa: usa «Supabase»."
            #expect(AssistantResearchAnswer.issues(in: observed, spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
            let citedAlternative = observed + " [B2]"
            #expect(AssistantResearchAnswer.issues(in: citedAlternative, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
            let displayed = AssistantResearchAnswer.resolvedText(observed, sources: sources)
            #expect(AssistantResearchAnswer.citationTokens(in: displayed) == ["B1", "B2"])
            #expect(displayed.contains("[B1]\(separator)[B2]"))
        }
    }

    @Test("Los campos de una propuesta separan elecciones citadas de límites pendientes")
    func validatesChoicesAndAlternativesWithoutCitingPendingLimits() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let valid = """
        ## Backend
        • Elección y encaje: «FastAPI» permite separar la API de la interfaz [B1].
        • Alternativa: «Supabase» sería provisional y sin respaldo de fuentes.
        • Límite pendiente: comprobar latencia y carga con el tráfico previsto.
        """
        #expect(AssistantResearchAnswer.issues(in: valid, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).isEmpty)
        let invalid = valid.replacingOccurrences(of: "sería provisional y sin respaldo de fuentes", with: "resuelve las cuentas de usuario")
        #expect(AssistantResearchAnswer.issues(in: invalid, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).contains { $0.contains("respaldo") })
        let differentScope = "## Backend\n• Elección y encaje: «FastAPI» para la API [B1].\n## Encaje del conjunto\nUsa FastAPI como API independiente [B1]."
        #expect(AssistantResearchAnswer.issues(in: differentScope, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).isEmpty)
    }

    @Test("Los límites pendientes son comprobaciones aunque contengan verbos de una elección")
    func distinguishesPendingChecksFromChoices() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n• Alternativa: «Supabase» sería provisional y sin respaldo de fuentes.\n"
        for check in ["usar pruebas de carga para comprobar la latencia.", "comprobar si utiliza demasiada memoria en producción."] {
            let text = base + "• Límite pendiente: " + check
            #expect(AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).isEmpty)
            let uncitedChoice = text.replacingOccurrences(of: " [B1]", with: "")
            #expect(AssistantResearchAnswer.issues(in: uncitedChoice, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).contains { $0.contains("respaldo") })
        }
    }

    @Test("Un subencabezado de alternativa conserva el componente y exige respaldo local")
    func preservesComponentScopeForAlternativeSubheadings() {
        func source(_ name: String, _ facets: Set<AssistantResearchFacet>) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API o almacenamiento de archivos", evidence: "", origin: .library,
                  facets: facets, collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI", [.engine]), "B2": source("Supabase", [.engine]), "B3": source("ObjectStore", [.storage])]
        let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n### Alternativa\n"
        let uncited = base + "«Supabase» es otra opción."
        #expect(AssistantResearchAnswer.issues(in: uncited, spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
        let cited = uncited + " [B2]"
        #expect(AssistantResearchAnswer.issues(in: cited, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
        #expect(AssistantResearchAnswer.issues(in: uncited + " [B1]", spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("«Supabase»") })
        let provisional = base + "«Supabase» sería provisional y sin respaldo de fuentes."
        #expect(AssistantResearchAnswer.issues(in: provisional, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
        let general = cited + "\n## Encaje del conjunto\n«ObjectStore» permite persistir archivos [B3]."
        #expect(AssistantResearchAnswer.issues(in: general, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
    }

    @Test("Los campos usan los tres separadores con cuerpo, subencabezado y líneas vacías")
    func parsesAnswerFieldsUniformly() {
        func source(_ name: String, _ facets: Set<AssistantResearchFacet>) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API o almacenamiento de archivos", evidence: "", origin: .library,
                  facets: facets, collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI", [.engine]), "B2": source("Supabase", [.engine]), "B3": source("ObjectStore", [.storage])]
        for separator in [":", "–", "—"] {
            for subheading in [false, true] {
                for gap in ["", "\n\n"] {
                    func field(_ label: String, _ content: String) -> String {
                        subheading ? "### \(label) \(separator)\n\(gap)\(content)" : "• \(label) \(separator) \(content)\(gap)"
                    }
                    let base = "## Backend\n" + field("Elección y encaje", "«FastAPI» sirve la API [B1].") + "\n"
                    let uncited = base + field("Alternativa", "«Supabase» es otra opción.")
                    #expect(AssistantResearchAnswer.issues(in: uncited, spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
                    let cited = base + field("Alternativa", "«Supabase» es otra opción [B2].")
                    #expect(AssistantResearchAnswer.issues(in: cited + "\n\n", spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                    let provisional = base + field("Alternativa", "«Supabase» sería provisional y sin respaldo de fuentes.")
                    #expect(AssistantResearchAnswer.issues(in: provisional, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                    let limit = cited + "\n" + field("Límite pendiente", "usar pruebas de carga para comprobar la latencia.")
                    #expect(AssistantResearchAnswer.issues(in: limit, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                    let general = cited + "\n## Encaje del conjunto\n«ObjectStore» permite persistir archivos [B3].\n\n"
                    #expect(AssistantResearchAnswer.issues(in: general, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                }
            }
        }
    }

    @Test("Un campo explícito de alternativa cierra la exención del límite pendiente")
    func changesFieldScopeAfterPendingLimit() {
        func source(_ name: String) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API", evidence: "", origin: .library,
                  facets: [.engine], collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI"), "B2": source("Supabase")]
        for separator in [":", "–", "—"] {
            let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n### Límite pendiente\nUsar pruebas de carga para comprobar la latencia.\n• Alternativa \(separator) «FastAPI» podría servir la API [B1].\n"
            let uncited = base + "Usa «Supabase» para cuentas."
            #expect(AssistantResearchAnswer.issues(in: uncited, spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
            #expect(AssistantResearchAnswer.issues(in: uncited + " [B2]", spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
            let provisional = base + "«Supabase» sería provisional y sin respaldo de fuentes."
            #expect(AssistantResearchAnswer.issues(in: provisional, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
        }
    }

    @Test("El rótulo de límite pendiente no exime una elección explícita de producto")
    func requiresBackingForChoicesInsidePendingLimit() {
        func source(_ name: String) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API", evidence: "", origin: .library,
                  facets: [.engine], collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI"), "B2": source("Supabase")]
        let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n"
        for separator in [":", "–", "—"] {
            for subheading in [false, true] {
                func limit(_ content: String) -> String {
                    subheading ? "### Límite pendiente \(separator)\n\n\(content)\n\n" : "• Límite pendiente \(separator) \(content)"
                }
                for choice in ["Recomiendo «Supabase» como alternativa.", "Usa «Supabase» para cuentas.", "«Supabase» es otra opción.", "Supabase es otra opción."] {
                    #expect(AssistantResearchAnswer.issues(in: base + limit(choice), spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
                    #expect(AssistantResearchAnswer.issues(in: base + limit(choice + " [B2]"), spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                }
                let provisional = "Recomiendo «Supabase» como alternativa provisional y sin respaldo de fuentes."
                #expect(AssistantResearchAnswer.issues(in: base + limit(provisional), spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                for check in ["usar pruebas de carga para comprobar la latencia.", "comprobar si utiliza demasiada memoria en producción.", "comprobar la latencia de «Supabase» antes de decidir."] {
                    #expect(AssistantResearchAnswer.issues(in: base + limit(check), spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                }
            }
        }
    }

    @Test("Una comprobación con tecnologías y verbos subordinados conserva su exención")
    func distinguishesMainChoiceFromNestedCheckActions() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n"
        let checks = [
            "medir el rendimiento al usar «FastAPI» con tráfico real.",
            "comprobar si «FastAPI» utiliza «SQLite» para persistir los datos.",
            "usar pruebas de carga con «FastAPI» para comprobar la latencia.",
            "comprobar si utiliza demasiada memoria con «FastAPI» en producción.",
            "«FastAPI»: comprobar la latencia antes de decidir."
        ]
        for separator in [":", "–", "—"] {
            for subheading in [false, true] {
                for marker in ["", "• ", "- ", "* ", "- [ ] ", "- [x] ", "- [X] ", "1. ", "1) ", "99. ", "99) "] {
                    for check in checks {
                        let field = subheading ? "### Límite pendiente \(separator)\n\n\(marker)\(check)\n\n" : "• Límite pendiente \(separator) \(marker)\(check)"
                        #expect(AssistantResearchAnswer.issues(in: base + field, spanish: true, sources: ["B1": source], requiredFacets: [.engine]).isEmpty)
                    }
                }
            }
        }
    }

    @Test("Los marcadores de lista no ocultan una elección dentro del límite pendiente")
    func detectsDecoratedChoicesInPendingLimit() {
        func source(_ name: String) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API", evidence: "", origin: .library,
                  facets: [.engine], collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI"), "B2": source("Supabase")]
        let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n"
        for separator in [":", "–", "—"] {
            for subheading in [false, true] {
                for marker in ["", "• ", "- ", "* ", "- [ ] ", "- [x] ", "- [X] ", "1. ", "1) ", "99. ", "99) "] {
                    for choice in ["Supabase es otra opción.", "«Supabase» es otra opción.", "Recomiendo «Supabase» como alternativa.", "Usa «Supabase» para cuentas.", "Recomiendo usar «Supabase» como alternativa.", "Usa el backend «Supabase» para cuentas."] {
                        func field(_ content: String) -> String {
                            subheading ? "### Límite pendiente \(separator)\n\n\(marker)\(content)\n\n" : "• Límite pendiente \(separator) \(marker)\(content)"
                        }
                        #expect(AssistantResearchAnswer.issues(in: base + field(choice), spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
                        #expect(AssistantResearchAnswer.issues(in: base + field(choice + " [B2]"), spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                        #expect(AssistantResearchAnswer.issues(in: base + field(choice + " [B1]"), spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("«Supabase»") })
                    }
                    func field(_ content: String) -> String {
                        subheading ? "### Límite pendiente \(separator)\n\n\(marker)\(content)\n\n" : "• Límite pendiente \(separator) \(marker) \(content)"
                    }
                    let provisional = "«Supabase» sería provisional y sin respaldo de fuentes."
                    #expect(AssistantResearchAnswer.issues(in: base + field(provisional), spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                }
            }
        }
    }

    @Test("Los campos explícitos comparten todos los marcadores de lista de la presentación")
    func parsesFieldsWithPresentationListMarkers() {
        func source(_ name: String) -> AssistantResearchSource {
            .init(title: name, url: "https://example.org/" + name.lowercased(), bookmarkID: nil,
                  summary: "Backend para crear una API", evidence: "", origin: .library,
                  facets: [.engine], collection: nil, tags: [])
        }
        let sources = ["B1": source("FastAPI"), "B2": source("Supabase")]
        let base = "## Backend\n• Elección y encaje: «FastAPI» sirve la API [B1].\n### Límite pendiente\nComprobar la latencia.\n"
        for marker in ["• ", "- ", "* ", "- [ ] ", "- [x] ", "- [X] ", "1. ", "1) ", "99. ", "99) "] {
            for separator in [":", "–", "—"] {
                let alternative = base + marker + "Alternativa \(separator) «Supabase» es otra opción."
                #expect(AssistantResearchAnswer.issues(in: alternative, spanish: true, sources: sources, requiredFacets: [.engine]).contains { $0.contains("respaldo") })
                #expect(AssistantResearchAnswer.issues(in: alternative + " [B2]", spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
                let check = base + marker + "Límite pendiente \(separator) usar pruebas de carga con «FastAPI» para comprobar la latencia."
                #expect(AssistantResearchAnswer.issues(in: check, spanish: true, sources: sources, requiredFacets: [.engine]).isEmpty)
            }
        }
    }

    @Test("La recomposición de rótulos es estable y conserva código y menciones ordinarias")
    func preservesLiteralContentAndStableComponentLayout() {
        let text = "Frontend: elección provisional sin respaldo de fuentes. Backend: elección provisional sin respaldo de fuentes."
        let once = AssistantResearchAnswer.componentLayout(text)
        #expect(AssistantResearchAnswer.componentLayout(once) == once)
        let literals = "Habla de un backend: con datos pendientes.\n«Frontend: conserva este texto literal.»\n```\nBackend: no es un apartado del plan\n```"
        #expect(AssistantResearchAnswer.componentLayout(literals) == literals)
        let incomplete = "Frontend: elección provisional. Backend"
        #expect(AssistantResearchAnswer.componentLayout(incomplete).hasSuffix("Backend"))
    }

    @Test("La revisión detecta un prefijo de edición incluso después de una cita")
    func detectsObservedSingleLetterEditingFragment() {
        let source = AssistantResearchSource(title: "FastAPI", url: "https://example.org/fastapi", bookmarkID: nil,
            summary: "Framework backend para crear una API", evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        #expect(AssistantResearchAnswer.issues(in: "Backend: usa FastAPI. [B1] F falta respaldo explíto de fuentes.", spanish: true, sources: ["B1": source]).contains { $0.contains("fragmentos sueltos") })
        #expect(!AssistantResearchAnswer.issues(in: "Backend: usa FastAPI. [B1] Falta verificar su rendimiento.", spanish: true, sources: ["B1": source]).contains { $0.contains("fragmentos sueltos") })
    }

    @Test("Las consultas agrupadas contrastan todas las responsabilidades con cuatro búsquedas máximas")
    func keepsGroupedResponsibilities() {
        let plan = AssistantResearchPlan.make(request: "Quiero crear un programa: frontend, backend, base de datos, búsqueda, almacenamiento y despliegue", priorUserRequests: [])
        let queries = plan.webQueries(coveredFacets: [])
        let roles = Set(queries.flatMap { $0.facets })
        #expect(queries.count == 4)
        #expect(roles.contains(.database) && roles.contains(.search) && roles.contains(.storage) && roles.contains(.deployment))
        #expect(queries.allSatisfy { $0.text.count <= 240 })
    }

    @Test("Planifica programas distintos sin depender de un dominio concreto")
    func plansDifferentPrograms() {
        for request in [
            "Quiero desarrollar un editor de música para Mac",
            "Diseña una aplicación para gestionar una clínica sin conexión",
            "Necesito crear un juego de estrategia",
            "Propón un stack para un servicio de mapas",
            "Hazme un programa de inventario",
            "Quiero montar un marketplace",
        ] {
            let plan = AssistantResearchPlan.make(request: request, priorUserRequests: [])
            #expect(plan.isSoftwarePlanning)
            #expect(plan.libraryQueries.count >= 4)
            #expect(plan.libraryQueries.allSatisfy { !$0.text.isEmpty })
        }
        #expect(!AssistantResearchPlan.make(request: "¿Qué es un programa?", priorUserRequests: []).isSoftwarePlanning)
        #expect(!AssistantResearchPlan.make(request: "Crea una colección para mis enlaces", priorUserRequests: []).isSoftwarePlanning)
    }

    @Test("Las alternativas conservan el programa y las restricciones del usuario")
    func followsUserContext() {
        let previous = ["Quiero desarrollar un editor de música para Mac", "Prefiero que funcione offline"]
        let followUp = AssistantResearchPlan.make(request: "¿Y si usamos Rust para el motor?", priorUserRequests: previous)
        #expect(followUp.isSoftwarePlanning)
        #expect(followUp.isFollowUp)
        #expect(followUp.contextRequest.contains("editor de música"))
        #expect(followUp.contextRequest.contains("offline"))
        #expect(followUp.libraryQueries.allSatisfy { $0.text.contains("Rust") })
        let requirements = AssistantResearchPlan.make(request: "Y que tenga usuarios y pagos", priorUserRequests: previous)
        #expect(requirements.isSoftwarePlanning)
        #expect(requirements.contextRequest.contains("editor de música"))
        #expect(requirements.libraryQueries.allSatisfy { $0.text.contains("usuarios") && $0.text.contains("pagos") })

        let other = AssistantResearchPlan.make(request: "Diseña una aplicación para una clínica", priorUserRequests: previous)
        #expect(!other.isFollowUp)
        #expect(!other.contextRequest.contains("música"))
        let unrelated = AssistantResearchPlan.make(request: "Cuenta mis enlaces", priorUserRequests: previous)
        #expect(!unrelated.isSoftwarePlanning)
    }

    @Test("Las consultas públicas eliminan secretos y rutas incluso si los escribió el usuario")
    func redactsPublicQueries() {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app para Mac en /Users/ana/privado con token=secreto123 y ana@example.com", priorUserRequests: [])
        for query in plan.webQueries(coveredFacets: []) {
            #expect(query.text.contains("Mac"))
            #expect(!query.text.contains("secreto123"))
            #expect(!query.text.contains("privado"))
            #expect(!query.text.contains("ana@example.com"))
            #expect(query.text.count <= 400)
        }
        let pem = "Quiero crear una app de mapas\n-----BEGIN RSA PRIVATE KEY-----\nCONTENIDO-PRIVADO-BASE64\n-----END RSA PRIVATE KEY-----"
        let safe = AssistantResearchPlan.make(request: pem, priorUserRequests: []).publicQuery(for: "CONTENIDO-PRIVADO-BASE64 motor")
        #expect(safe?.contains("mapas") == true)
        #expect(safe?.contains("CONTENIDO-PRIVADO") == false)
        #expect(plan.publicQuery(for: "CLIENTE-883-P documentación")?.contains("CLIENTE") == false)
    }

    @Test("El dossier deduplica procedencia y mejora evidencia sin fabricar referencias")
    func preservesSources() {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let saved = AssistantResearchSource(title: "Motor de audio", url: "https://example.org/audio", bookmarkID: id,
            summary: "Procesamiento de audio", evidence: "Fragmento local", origin: .library,
            facets: [.engine], collection: "Audio", tags: [])
        let web = AssistantResearchSource(title: "Documentación de audio", url: "https://example.org/audio?utm_source=docs", bookmarkID: nil,
            summary: "Documentación pública", evidence: "Resultado web", origin: .web,
            facets: [.quality], collection: nil, tags: [])
        var dossier = AssistantResearchDossier()
        dossier.append(.init(sources: [saved], candidateCount: 1), query: .init(facet: .engine, text: "audio"), web: false)
        dossier.append(.init(sources: [web], candidateCount: 1), query: .init(facet: .quality, text: "audio docs"), web: true)
        dossier.updatePage(.init(title: "Audio", url: "https://example.org/audio", text: "Requisitos públicos comprobados"))
        #expect(dossier.sources.count == 1)
        #expect(dossier.references.count == 1)
        #expect(dossier.references.first?.origin == .library)
        #expect(dossier.didReadWebSource)
        #expect(dossier.context(maximumCharacters: 4_000).contains("página web leída"))
        #expect(dossier.context(maximumCharacters: 4_000).contains("Requisitos públicos comprobados"))
    }

    @Test("Los valores secretos entre comillas se redactan completos antes de buscar")
    @MainActor
    func redactsQuotedSecrets() async throws {
        for assignment in [
            #"password = "PRIMERA SEGUNDA PRIVADA""#,
            #"token = 'PRIMERA SEGUNDA PRIVADA'"#,
            #"secret = "PRIMERA SEGUNDA PRIVADA"#,
            #"contraseña = 'PRIMERA SEGUNDA PRIVADA"#,
            #"api_key = "PRIMERA \"SEGUNDA\" PRIVADA""#,
            "password = \"PRIMERA\nSEGUNDA PRIVADA\"",
        ] {
            let plan = AssistantResearchPlan.make(
                request: "Quiero crear una app de mapas, \(assignment)", priorUserRequests: []
            )
            let redacted = AssistantActionPolicy.publicWebContext(assignment)
            #expect(!redacted.contains("PRIMERA"))
            #expect(!redacted.contains("SEGUNDA"))
            #expect(!redacted.contains("PRIVADA"))
            var outbound: [String] = []
            _ = try await AssistantResearchCoordinator.collect(
                plan: plan, webEnabled: true,
                librarySearch: { _ in .init(sources: [], candidateCount: 0) },
                webSearch: { query in
                    outbound.append(query.text)
                    return .init(sources: [], candidateCount: 0)
                },
                readPage: { _ in throw AssistantWebError.invalidURL },
                progress: { _ in }
            )
            #expect(!outbound.isEmpty)
            #expect(outbound.allSatisfy { !$0.contains("PRIMERA") && !$0.contains("SEGUNDA") && !$0.contains("PRIVADA") })
        }
    }

    @Test("Una página leída entra en el contexto aunque las notas locales sean largas")
    func keepsReadEvidence() {
        let source = AssistantResearchSource(title: "Motor", url: "https://example.org/engine", bookmarkID: UUID(),
            summary: "NOTA-LOCAL: " + String(repeating: "n", count: 1_800), evidence: "", origin: .library,
            facets: [.engine], collection: nil, tags: [])
        var dossier = AssistantResearchDossier()
        dossier.append(.init(sources: [source], candidateCount: 1), query: .init(facet: .engine, text: "motor"), web: false)
        dossier.updatePage(.init(title: "Motor", url: "https://example.org/engine", text: "EVIDENCIA-WEB: la documentación describe el formato FLAC. " + String(repeating: "w", count: 1_000)))
        let context = dossier.context(maximumCharacters: 2_000)
        #expect(context.contains("NOTA-LOCAL"))
        #expect(context.contains("EVIDENCIA-WEB"))
        #expect(context.contains("Texto de la página leída"))
        #expect(context.contains("formato FLAC"))
    }

    @Test("Las páginas adicionales reutilizan el ranking ya recuperado sin otro runtime")
    func pagesRetrievedCandidates() {
        let sources = (0..<100).map { index in
            AssistantResearchSource(title: "Audio \(index)", url: "https://example.org/audio/\(index)", bookmarkID: nil,
                summary: "Motor de audio", evidence: "Fragmento recuperado", origin: .library,
                facets: [.engine], collection: nil, tags: [])
        }
        var cache = AssistantResearchCache()
        cache.insert(.init(sources: sources, candidateCount: 100), query: "motor de audio")
        let page = cache.page(query: "motor de audio", offset: 24, limit: 24)
        #expect(page.candidateCount == 100)
        #expect(page.sources.count == 24)
        #expect(page.sources.first?.title == "Audio 24")
        #expect(page.sources.last?.title == "Audio 47")
        #expect(cache.page(query: "vídeo desconocido", offset: 0, limit: 24).sources.isEmpty)
    }

    @Test("El presupuesto conserva responsabilidades y explicita los límites")
    func balancesBoundedContext() {
        var dossier = AssistantResearchDossier()
        for (index, facet) in AssistantResearchFacet.allCases.enumerated() {
            let source = AssistantResearchSource(title: "Recurso \(facet.title)", url: "https://example.org/\(index)", bookmarkID: nil,
                summary: String(repeating: "Contenido ", count: 300), evidence: "Evidencia", origin: .library,
                facets: [facet], collection: nil, tags: [])
            dossier.append(.init(sources: [source], candidateCount: 200), query: .init(facet: facet, text: facet.title), web: false)
        }
        let context = dossier.context(maximumCharacters: 6_000)
        #expect(context.count <= 6_000)
        #expect(context.contains("Recurso Almacenamiento"))
        #expect(context.contains("Recurso Integración y exportación"))
        #expect(context.contains("no se garantiza recuperación exhaustiva"))
        #expect(AssistantResearchDossier.contextCharacterBudget(contextWindow: 4_096) < AssistantResearchDossier.contextCharacterBudget(contextWindow: 32_768))
        for index in 0..<20 { dossier.recordNotice("Error \(index): " + String(repeating: "x", count: 500)) }
        #expect(dossier.context(maximumCharacters: 900).count <= 900)
    }

    @Test("Con web desactivada no se consulta ni se lee ninguna página")
    @MainActor
    func respectsDisabledWeb() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app de mapas", priorUserRequests: [])
        var networkCalls = 0
        let dossier = try await AssistantResearchCoordinator.collect(plan: plan, webEnabled: false,
            librarySearch: { _ in .init(sources: [], candidateCount: 0) },
            webSearch: { _ in networkCalls += 1; return .init(sources: [], candidateCount: 0) },
            readPage: { _ in networkCalls += 1; return .init(title: "", url: "", text: "") },
            progress: { _ in })
        #expect(networkCalls == 0)
        #expect(dossier.librarySearches == 6)
        #expect(dossier.notices.contains { $0.contains("desactivada") })
    }

    @Test("La biblioteca privada nunca entra en consultas de Internet")
    @MainActor
    func keepsPrivateEvidenceLocal() async throws {
        let request = "Quiero crear una app de mapas con token = SECRETO-CON-ESPACIOS\n-----BEGIN RSA PRIVATE KEY-----\nPEM-MULTILINEA-SIN-CIERRE"
        let plan = AssistantResearchPlan.make(request: request, priorUserRequests: [])
        var outboundQueries: [String] = []
        let privateSource = AssistantResearchSource(title: "Proyecto secreto del cliente", url: nil, bookmarkID: UUID(),
            summary: "Identificador privado CIENTE-883-P", evidence: "/Users/ana/documentos", origin: .library,
            facets: [.overview], collection: nil, tags: [])
        let dossier = try await AssistantResearchCoordinator.collect(plan: plan, webEnabled: true,
            librarySearch: { _ in .init(sources: [privateSource], candidateCount: 1) },
            webSearch: { query in outboundQueries.append(query.text); return .init(sources: [], candidateCount: 0) },
            readPage: { _ in Issue.record("No hay URLs reales que leer"); return .init(title: "", url: "", text: "") },
            progress: { _ in })
        #expect(!outboundQueries.isEmpty)
        #expect(outboundQueries.allSatisfy { !$0.contains("secreto") && !$0.contains("CIENTE") && !$0.contains("ana") })
        #expect(outboundQueries.allSatisfy { !$0.contains("SECRETO-CON-ESPACIOS") && !$0.contains("PEM-MULTILINEA") })
        #expect(dossier.sources.first?.title == "Proyecto secreto del cliente")
        #expect(dossier.references.isEmpty)
    }

    @Test("La lectura prioriza el tema público sin prestar URLs de la biblioteca")
    @MainActor
    func readsRelevantPublicPagesFirst() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D local con IA", priorUserRequests: [])
        #expect(!plan.isSoftwarePlanning && plan.requiresSourceResearch)
        let irrelevant = AssistantResearchSource(title: "Inferencia local de lenguaje", url: "https://llm.example.org/guide", bookmarkID: nil,
            summary: "Guía para optimizar memoria de modelos de texto.", evidence: "", origin: .web, facets: [.overview], collection: nil, tags: [])
        let first3D = AssistantResearchSource(title: "Generación 3D local con IA", url: "https://geometry.example.org/first", bookmarkID: nil,
            summary: "Medir la generación 3D local.", evidence: "", origin: .web, facets: [.overview], collection: nil, tags: [])
        let second3D = AssistantResearchSource(title: "Generación 3D local con IA", url: "https://mesh.example.org/second", bookmarkID: nil,
            summary: "Medir la generación 3D local.", evidence: "", origin: .web, facets: [.overview], collection: nil, tags: [])
        var readURLs: [String] = []
        _ = try await AssistantResearchCoordinator.collect(plan: plan, webEnabled: true,
            librarySearch: { _ in .init(sources: [], candidateCount: 0) },
            webSearch: { _ in .init(sources: [irrelevant, first3D, second3D], candidateCount: 3) },
            readPage: { url in readURLs.append(url); return .init(title: "Guía", url: url, text: "Contenido público") },
            progress: { _ in })
        #expect(readURLs == [first3D.url!, second3D.url!, irrelevant.url!])
    }

    @Test("Al contrastar una fuente guardada solo se lee la URL exacta encontrada en web")
    @MainActor
    func readsPublicResultURL() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app de mapas", priorUserRequests: [])
        var readURLs: [String] = []
        let saved = AssistantResearchSource(title: "Mapas", url: "http://www.example.org/maps?utm_source=privado", bookmarkID: UUID(),
            summary: "Notas locales", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        let publicResult = AssistantResearchSource(title: "Mapas", url: "https://example.org/maps", bookmarkID: nil,
            summary: "Documentación", evidence: "", origin: .web, facets: [.overview], collection: nil, tags: [])
        let dossier = try await AssistantResearchCoordinator.collect(plan: plan, webEnabled: true,
            librarySearch: { _ in .init(sources: [saved], candidateCount: 1) },
            webSearch: { _ in .init(sources: [publicResult], candidateCount: 1) },
            readPage: { url in readURLs.append(url); return .init(title: "Mapas", url: url, text: "API pública de mapas") },
            progress: { _ in })
        #expect(readURLs == ["https://example.org/maps"])
        #expect(dossier.sources.count == 1)
        #expect(dossier.didReadWebSource)
    }

    @Test("Una cancelación interrumpe la investigación antes de salir a Internet")
    @MainActor
    func cancelsResearch() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear un programa de mapas", priorUserRequests: [])
        var networkCalls = 0
        await #expect(throws: CancellationError.self) {
            _ = try await AssistantResearchCoordinator.collect(plan: plan, webEnabled: true,
                librarySearch: { _ in throw CancellationError() },
                webSearch: { _ in networkCalls += 1; return .init(sources: [], candidateCount: 0) },
                readPage: { _ in networkCalls += 1; return .init(title: "", url: "", text: "") },
                progress: { _ in })
        }
        #expect(networkCalls == 0)
    }

    @Test("Autorizar una URL pública no autoriza los parámetros privados de un enlace guardado")
    func authorizesExactWebURLs() {
        let publicURL = "https://example.org/maps"
        let keys = Set([AssistantResearchWebURLAuthorization.key(publicURL)!])
        #expect(AssistantResearchWebURLAuthorization.allows(publicURL, authorizedKeys: keys))
        for variant in [
            "https://example.org/maps?utm_source=CLIENTE",
            "https://example.org/maps?mc_eid=IDENTIFICADOR",
            "http://example.org/maps",
            "https://www.example.org/maps",
            "https://example.org/maps/",
        ] {
            #expect(!AssistantResearchWebURLAuthorization.allows(variant, authorizedKeys: keys))
        }
        let explicitURL = "https://example.org/maps?utm_source=CLIENTE&mc_eid=IDENTIFICADOR"
        let userKeys = AssistantResearchWebURLAuthorization.detectedKeys(in: "Lee \(explicitURL)")
        #expect(AssistantResearchWebURLAuthorization.allows(explicitURL, authorizedKeys: userKeys))
        #expect(!AssistantResearchWebURLAuthorization.allows(publicURL, authorizedKeys: userKeys))
        #expect(!AssistantResearchWebURLAuthorization.allows("https://example.org/maps?mc_eid=IDENTIFICADOR&utm_source=CLIENTE", authorizedKeys: userKeys))
    }
}


extension AssistantResearchTests {
    @Test("Una negación con varias identidades sin sujeto local inequívoco se rechaza por ambigüedad")
    func rejectsAmbiguousCapabilityAbsence() {
        let without = AssistantResearchSource(title: "EngineWithoutUI", url: "https://example.org/minimal", bookmarkID: nil,
            summary: "EngineWithoutUI implementa backend y API sin interfaz frontend.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        let withUI = AssistantResearchSource(title: "EngineWithUI", url: "https://example.org/panel", bookmarkID: nil,
            summary: "EngineWithUI implementa backend y API con interfaz frontend y panel de administración.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": without, "B2": withUI]
        for prose in ["EngineWithUI, frente a EngineWithoutUI, funciona sin interfaz frontend.",
                      "EngineWithoutUI, frente a EngineWithUI, funciona sin interfaz frontend.",
                      "EngineWithUI y EngineWithoutUI funcionan sin interfaz frontend."] {
            let issues = AssistantResearchAnswer.structuredAbsenceIssues(in: prose, primaryID: "B2", allowedIDs: ["B1", "B2"], sources: sources)
            #expect(issues.contains { $0.contains("ambigua") })
        }
    }

    @Test("El sujeto explícito de una negación se conserva al principio, tras coma y en otra oración")
    func preservesExplicitAbsenceClauses() {
        let without = AssistantResearchSource(title: "EngineWithoutUI", url: "https://example.org/minimal", bookmarkID: nil,
            summary: "EngineWithoutUI implementa backend y API sin interfaz frontend.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        let withUI = AssistantResearchSource(title: "EngineWithUI", url: "https://example.org/panel", bookmarkID: nil,
            summary: "EngineWithUI implementa backend y API con interfaz frontend y panel de administración.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        let sources = ["B1": without, "B2": withUI]
        for prose in ["EngineWithoutUI funciona sin interfaz frontend, frente a EngineWithUI.",
                      "EngineWithUI sirve la API, mientras que EngineWithoutUI funciona sin interfaz frontend.",
                      "EngineWithUI sirve la API. EngineWithoutUI funciona sin interfaz frontend.",
                      "EngineWithoutUI funciona, sin interfaz frontend.",
                      "EngineWithUI sirve la API; EngineWithoutUI funciona sin interfaz frontend."] {
            #expect(AssistantResearchAnswer.structuredAbsenceIssues(in: prose, primaryID: "B2", allowedIDs: ["B1", "B2"], sources: sources).isEmpty)
        }
        for prose in ["EngineWithUI funciona sin interfaz frontend, frente a EngineWithoutUI.",
                      "EngineWithoutUI sirve la API, mientras que EngineWithUI funciona sin interfaz frontend.",
                      "EngineWithoutUI sirve la API. EngineWithUI funciona sin interfaz frontend.",
                      "EngineWithoutUI sirve la API; EngineWithUI funciona sin interfaz frontend."] {
            #expect(!AssistantResearchAnswer.structuredAbsenceIssues(in: prose, primaryID: "B1", allowedIDs: ["B1", "B2"], sources: sources).isEmpty)
        }
    }
}


extension AssistantResearchTests {
    @Test("La ausencia descrita para otra herramienta en los metadatos no se presta al producto de la fuente")
    @MainActor
    func rejectsAbsenceBorrowedFromOtherSourceMetadata() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
        let without = AssistantResearchSource(title: "EngineWithoutUI", url: "https://example.org/minimal", bookmarkID: nil,
            summary: "EngineWithoutUI implementa backend y API sin interfaz frontend.", evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
        for summary in ["EngineWithUI implementa backend y API con interfaz frontend.",
                        "EngineWithUI implementa backend y API con interfaz frontend. EngineWithoutUI implementa backend y API sin interfaz frontend."] {
            let withUI = AssistantResearchSource(title: "EngineWithUI", url: "https://example.org/panel", bookmarkID: nil,
                summary: summary, evidence: "", origin: .library, facets: [.engine], collection: nil, tags: [])
            var dossier = AssistantResearchDossier()
            dossier.append(.init(sources: [withUI, without], candidateCount: 2), query: .init(facet: .engine, text: "backend"), web: false)
            for (difference, accepted) in [("EngineWithUI funciona sin interfaz frontend.", false),
                                           ("EngineWithoutUI funciona sin interfaz frontend.", true)] {
                let result = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4096) { _ in
                    structured([component("engine", choice: "B1", alternative: "B2", fit: "Implementa la API del programa.", difference: difference)])
                }
                #expect(result.issues.isEmpty == accepted)
            }
        }
    }
}


extension AssistantResearchTests {
    private func resumeSource(_ title: String, _ summary: String, facet: AssistantResearchFacet = .engine) -> AssistantResearchSource {
        .init(title: title, url: "https://example.org/" + title.lowercased(), bookmarkID: nil, summary: summary, evidence: "", origin: .library, facets: [facet], collection: nil, tags: [])
    }
}

import Foundation
import Testing

extension AssistantResearchTests {
    @Test("Reanudación: temporal hijo restaura el marco, flexión no acreditada falla explícitamente")
    func resume128Domains() {
        let records = ["B1": resumeSource("ApiOne", "ApiOne implementa backend mediante una API REST. Permite exportación JSON."),
                       "B2": resumeSource("ApiTwo", "ApiTwo implementa backend mediante una API SOAP. Permite exportación CSV."),
                       "B3": resumeSource("DataStore", "DataStore conserva una base de datos SQL. Permite exportación CSV.", facet: .database)]
        let cases: [(String, Bool)] = [
            ("ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL mientras ApiTwo permite exportación CSV; además permite exportación JSON.", true),
            ("ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL mientras ApiTwo permite exportación CSV; además permite exportación CSV.", false),
            ("ApiOne ofreció una API para que ApiTwo consultara una base de datos SQL y ApiTwo exportara CSV; actualmente permite exportación CSV.", false),
            ("ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL y ApiTwo exporte CSV; además permite exportación JSON.", true),
            ("ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL y ApiTwo exporte CSV; además permite exportación CSV.", false),
            ("ApiOne ofrece una API para que DataStore consulte una base de datos SQL; ApiOne puede exportar JSON.", true)
        ]
        for (text, expected) in cases {
            let issues = AssistantResearchAnswer.structuredCapabilityIssues(in: text, defaultSubjectIDs: ["B2"], allowedIDs: Set(records.keys), sources: records)
            print("RESUME128_DOMAIN", expected, text, issues)
            #expect(issues.isEmpty == expected, Comment(rawValue: text))
            if text.contains("exportara") { #expect(issues.contains { $0.contains("indeterminado") }) }
        }
    }
}

extension AssistantResearchTests {
    @Test("Reanudación: un predicado parentético no sustituye al sujeto exterior")
    func resume128Parenthetical() {
        let records = ["B1": resumeSource("ApiOne", "ApiOne implementa backend mediante una API REST. Permite exportación JSON."),
                       "B2": resumeSource("SoapEngine", "SoapEngine implementa backend mediante una API SOAP. Permite exportación CSV.")]
        for (format, expected) in [("JSON", true), ("CSV", false)] {
            let text = "ApiOne implementa una API REST (SoapEngine permite exportación CSV). Además permite exportación " + format + "."
            let issues = AssistantResearchAnswer.structuredCapabilityIssues(in: text, defaultSubjectIDs: ["B2"], allowedIDs: Set(records.keys), sources: records)
            print("RESUME128_PAREN", expected, text, issues)
            #expect(issues.isEmpty == expected)
        }
    }
}

extension AssistantResearchTests {
    @Test("Reanudación: una modalidad con sujeto explícito exige acreditar su nivel")
    func resume128ExplicitModalUncertainty() {
        let records = ["B1": resumeSource("ApiOne", "ApiOne implementa backend mediante una API REST. Permite exportación JSON."),
                       "B2": resumeSource("DataStore", "DataStore conserva una base de datos SQL. Permite exportación CSV.", facet: .database)]
        for format in ["JSON", "CSV"] {
            let prose = "ApiOne ofrece una API para que DataStore consulte una base de datos SQL y ApiOne puede exportar " + format + "."
            let issues = AssistantResearchAnswer.structuredCapabilityIssues(in: prose, defaultSubjectIDs: ["B1"], allowedIDs: Set(records.keys), sources: records)
            print("RESUME128_MODAL_UNCERTAINTY", format, issues)
            #expect(issues.contains { $0.contains("indeterminado") })
        }
    }
}

import Foundation
import Testing
extension AssistantResearchTests {
    @Test("Reanudación: matriz causal literal PLAN128 sin cambiar expectativas")
    func resume128LiteralMatrix() {
        let cases: [(String, String, Bool, String)] = [
            ("spec-present-ar-final-JSON", "ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL y ApiTwo exporte CSV; además permite exportación JSON.", true, "spec127"),
            ("spec-present-ar-final-CSV", "ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL y ApiTwo exporte CSV; además permite exportación CSV.", false, "spec127"),
            ("spec-temporal-present-JSON", "ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL mientras ApiTwo permite exportación CSV; además permite exportación JSON.", true, "spec127"),
            ("spec-temporal-present-CSV", "ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL mientras ApiTwo permite exportación CSV; además permite exportación CSV.", false, "spec127"),
            ("spec-past-ar-foreign", "ApiOne ofreció una API para que ApiTwo consultara una base de datos SQL y ApiTwo exportara CSV; actualmente permite exportación CSV.", false, "spec127"),
            ("parenthetical-es", "ApiOne implementa una API REST. SoapEngine y ApiOne (ambos) implementan una API REST.", false, "standards127"),
            ("parenthetical-backed-es", "ApiOne implementa una API REST. SoapEngine y ApiOne (ambos) implementan una API REST.", true, "standards127-backed"),
            ("parenthetical-en", "ApiOne implements a REST API. SoapEngine and ApiOne (both) implement a REST API.", false, "standards127"),
            ("parenthetical-backed-en", "ApiOne implements a REST API. SoapEngine and ApiOne (both) implement a REST API.", true, "standards127-backed"),
            ("pueda-JSON", "ApiOne ofrece una API para que DataStore consulte una base de datos SQL y pueda exportar CSV. Además permite exportación JSON.", true, "standards127"),
            ("pueda-CSV", "ApiOne ofrece una API para que DataStore consulte una base de datos SQL y pueda exportar CSV. Además permite exportación CSV.", false, "standards127"),
            ("title-11", "«Motor tanto uno como dos» ofrece una API para que DataStore consulte una base de datos SQL, pero además permite exportación JSON.", true, "standards127-title"),
            ("title-12", "«Motor tanto uno como dos» ofrece una API para que DataStore consulte una base de datos SQL, pero además permite exportación CSV.", false, "standards127-title"),
            ("title-13", "«Engine both this and that» ofrece una API para que DataStore consulte una base de datos SQL, pero además permite exportación JSON.", true, "standards127-title"),
            ("title-14", "«Engine both this and that» ofrece una API para que DataStore consulte una base de datos SQL, pero además permite exportación CSV.", false, "standards127-title"),
            ("title-15", "«🧩 Motor junto con datos. Real» ofrece una API para que DataStore consulte una base de datos SQL, pero además permite exportación JSON.", true, "standards127-title"),
            ("title-16", "«🧩 Motor junto con datos. Real» ofrece una API para que DataStore consulte una base de datos SQL, pero además permite exportación CSV.", false, "standards127-title"),
            ("english-it", "ApiOne provides an API for DataStore to query a SQL database, but it also exports CSV.", false, "standards127"),
            ("english-explicit-JSON", "ApiOne provides an API for DataStore to query a SQL database and export CSV. ApiOne exports JSON.", true, "standards127"),
            ("english-explicit-CSV", "ApiOne provides an API for DataStore to query a SQL database and export CSV. ApiOne exports CSV.", false, "standards127"),
            ("principal-change-CSV", "ApiOne ofrece una API para que DataStore consulte una base de datos SQL; SoapEngine permite exportación CSV. Además permite exportación CSV.", true, "standards127"),
            ("principal-change-JSON", "ApiOne ofrece una API para que DataStore consulte una base de datos SQL; SoapEngine permite exportación CSV. Además permite exportación JSON.", false, "standards127"),
            ("object-not-subject-JSON", "ApiOne utiliza la API de SoapEngine. Además permite exportación JSON.", true, "standards127"),
            ("object-not-subject-CSV", "ApiOne utiliza la API de SoapEngine. Además permite exportación CSV.", false, "standards127"),
            ("object-ambiguous", "Conecta la API de ApiOne con la base de datos de DataStore. Permite exportación CSV.", false, "standards127"),
            ("temporal-body-JSON", "ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL mientras ApiTwo permite exportación CSV; además permite exportación JSON.", true, "spec127"),
            ("temporal-body-CSV", "ApiOne ofrece una API para que ApiTwo consulte una base de datos SQL mientras ApiTwo permite exportación CSV; además permite exportación CSV.", false, "spec127"),
            ("present-modal-control", "ApiOne ofrece una API para que DataStore consulte una base de datos SQL; ApiOne puede exportar JSON.", true, "standards127"),
            ("atomic-punctuation", "«🧩 Motor junto con datos. Real» ofrece una API REST. Además permite exportación JSON.", true, "standards127-title"),
        ]
        for (id, prose, expected, fixture) in cases {
            let more = fixture == "standards127-backed" ? " Implementa una API REST y una API SOAP. Permite exportación JSON y CSV." : ""
            let title = fixture == "standards127-title" ? String(prose.split(separator: "«")[0].split(separator: "»")[0]) : "ApiOne"
            var records = ["B1": resumeSource(title, title + " implementa backend mediante una API REST. Permite exportación JSON." + more),
                           "B2": resumeSource("SoapEngine", "SoapEngine implementa backend mediante una API SOAP. Permite exportación CSV." + more),
                           "B3": resumeSource("DataStore", "DataStore conserva una base de datos SQL. Permite exportación CSV.", facet: .database),
                           "B4": resumeSource("TercerMotor", "TercerMotor implementa backend mediante una API REST. Permite exportación JSON." + more)]
            if fixture == "spec127" {
                records["B2"] = resumeSource("ApiTwo", "ApiTwo implementa backend mediante una API SOAP. Permite exportación CSV.")
            }
            for defaultIDs: Set<String> in [[], ["B1"], ["B2"]] {
                let issues = AssistantResearchAnswer.structuredCapabilityIssues(in: prose, defaultSubjectIDs: defaultIDs, allowedIDs: Set(records.keys), sources: records)
                print("PLAN128_LITERAL", id, defaultIDs.sorted(), expected, issues)
                #expect(issues.isEmpty == expected, Comment(rawValue: id + " " + defaultIDs.sorted().joined(separator: ",")))
            }
        }
    }
}

extension AssistantResearchTests {
    @Test("Reanudación: Composer conserva la prosa literal respaldada y excluye préstamos en cada campo")
    @MainActor
    func resume128ComposerFields() async throws {
        for backed in [false, true] {
            let more = backed ? " Implementa una API REST y una API SOAP. Permite exportación JSON y CSV." : ""
            let a = resumeSource("ApiOne", "ApiOne implementa backend mediante una API REST. Permite exportación JSON." + more)
            let b = resumeSource("SoapEngine", "SoapEngine implementa backend mediante una API SOAP. Permite exportación CSV." + more)
            let db = resumeSource("DataStore", "DataStore conserva una base de datos SQL.", facet: .database)
            var dossier = AssistantResearchDossier()
            dossier.append(.init(sources: [a, b, db], candidateCount: 3), query: .init(facet: .engine, text: "backend"), web: false)
            let indexed = dossier.indexedSources
            let aID = try #require(indexed.first { $0.1.title == "ApiOne" }?.0)
            let bID = try #require(indexed.first { $0.1.title == "SoapEngine" }?.0)
            let dbID = try #require(indexed.first { $0.1.title == "DataStore" }?.0)
            let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
            for field in ["difference", "integration"] {
                let prose = "ApiOne implementa una API REST. SoapEngine y ApiOne (ambos) implementan una API REST."
                let result = try await composeFixture(plan: plan, dossier: dossier, spanish: true, outputTokens: 4096) { round in
                    structured(round.purpose == .composition ? [
                        component("engine", choice: aID, alternative: bID, fit: "ApiOne implementa una API REST.", difference: field == "difference" ? prose : "SoapEngine implementa una API SOAP."),
                        component("database", choice: dbID, fit: "Conserva los datos estructurados del programa.")
                    ] : [], integration: field == "integration" ? prose : "La API elegida accede a la base de datos del programa.")
                }
                #expect(result.issues.isEmpty == backed)
                #expect((Data(result.text.utf8).range(of: Data(prose.utf8)) != nil) == backed)
                if backed { #expect(result.rounds == 1) }
            }
        }
    }
}

extension AssistantResearchTests {
    @Test("Frontera CPU: cancelar durante los checks no devuelve una composición aceptada")
    @MainActor
    func mainactorPlanCancellationDuringValidation() async throws {
        let worker = Task { @MainActor in
            let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend.", priorUserRequests: [])
            let fit = "PocketBase encaja como backend ligero y único archivo, ideal para proyectos que buscan simplicidad y fácil integración sin complejidad adicional."
            let difference = "T1T0Dev/E-COMMERCE utiliza un stack full-stack (React, Express, MySQL) y está diseñado para entornos empresariales reales, mientras que PocketBase es un backend minimalista en un solo archivo."
            return try await composeFixture(plan: plan, dossier: pilotBackendDossier(), spanish: true, outputTokens: 4096,
                detectedLanguage: { _ in withUnsafeCurrentTask { $0?.cancel() }; return "es" }) { _ in
                    MainActor.preconditionIsolated()
                    return structured([component("engine", choice: "B1", alternative: "W2", fit: fit, difference: difference)])
                }
        }
        await #expect(throws: CancellationError.self) { _ = try await worker.value }
    }
}

@Suite("Investigación genérica — continuidad y procedencia")
struct GenericResearchRegressionTests {
    @Test("Simplificar mantiene el tema 3D y consulta la pregunta completa")
    func simplifyingKeepsOriginalTopic() {
        let original = "quiero optimizar mi generación 3D en local con IA, cómo lo hago?"
        let plan = AssistantResearchPlan.make(request: "y simplificar", priorUserRequests: [original])
        #expect(plan.isFollowUp)
        #expect(plan.requiresSourceResearch)
        #expect(!plan.isSoftwarePlanning)
        #expect(plan.contextRequest.contains(original))
        #expect(plan.libraryQueries.first?.text.contains(original) == true)
    }
    @Test("Una validación documental declarada requiere lectura de las fuentes")
    func rejectsUnreadValidation() {
        let source = AssistantResearchSource(title: "Vivago", url: "https://example.org/vivago", bookmarkID: nil, summary: "Generación 3D", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        let text = "Esta estrategia ha sido validada por la documentación oficial de cada herramienta."
        #expect(!AssistantResearchAnswer.issues(in: text, spanish: true, sources: ["B1": source]).isEmpty)
    }
}

@Suite("Respuesta libre — revisión acotada con fuentes reales")
struct GenericResearchReviewTests {
    private func source(read: Bool = false) -> AssistantResearchSource {
        var s = AssistantResearchSource(title: "Vivago", url: "https://example.org/vivago", bookmarkID: nil, summary: "Vivago permite generación 3D.", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        s.pageWasRead = read
        return s
    }
    @Test("No presta B1 a otra herramienta del historial")
    func rejectsBorrowedCitation() {
        #expect(!AssistantResearchAnswer.adviceIssues(in: "Utiliza Modly para generar modelos [B1].", spanish: true, sources: ["B1": source()]).isEmpty)
        #expect(AssistantResearchAnswer.adviceIssues(in: "Como opción provisional y sin respaldo, considera Modly; falta verificar sus requisitos.", spanish: true, sources: [:]).isEmpty)
        #expect(AssistantResearchAnswer.historicalText("Vivago [B1], otro resultado (W2).") == "Vivago , otro resultado .")
    }
    @Test("La lectura de una fuente no verifica otras ni citas ausentes")
    func verifiesPerSource() {
        var other = source(); other = .init(title: "ToolTwo", url: "https://example.org/two", bookmarkID: nil, summary: "Otro candidato", evidence: "", origin: .web, facets: [.overview], collection: nil, tags: [])
        let sources = ["B1": source(read: true), "W2": other]
        for text in ["La documentación verificada respalda el proceso [W2].", "Esta estrategia ha sido validada por documentación verificada [W2].", "Esta estrategia ha sido validada por la documentación oficial [B1].", "La estrategia ha sido validada por la documentación oficial.", "The strategy was validated by official documentation [W2]."] {
            #expect(!AssistantResearchAnswer.provenanceIssues(in: text, sources: sources).isEmpty)
        }
        for text in ["Según la documentación verificada [B1].", "No ha sido validada por la documentación oficial [W2].", "Falta confirmar si puede ser validada por la documentación oficial [W2].", "El ejemplo dice «estrategia validada por la documentación».", "```\nEstrategia validada por la documentación.\n```"] {
            #expect(AssistantResearchAnswer.provenanceIssues(in: text, sources: sources).isEmpty)
        }
    }
    @Test("Simplificar no arrastra otro tema ni supera los cinco turnos")
    func boundedContinuation() {
        let original = "quiero optimizar mi generación 3D en local con IA, cómo lo hago?"
        for request in ["Quiero simplificar mi biblioteca", "y simplificar mi cocina", "Otro tema: quiero optimizar mi código y simplificar la app"] {
            let plan = AssistantResearchPlan.make(request: request, priorUserRequests: [original])
            #expect(!plan.isFollowUp)
            #expect(!plan.contextRequest.contains(original))
        }
        let stale = AssistantResearchPlan.make(request: "y simplificar", priorUserRequests: [original] + Array(repeating: "mensaje distinto", count: 5))
        #expect(!stale.isFollowUp)
        let withoutPrior = AssistantResearchPlan.make(request: "y simplificar", priorUserRequests: [])
        #expect(!withoutPrior.isFollowUp)
    }
    @Test("Publica consejos respaldados sin imponer componentes de software")
    @MainActor
    func acceptsGroundedAdvice() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar mi generación 3D local con IA, ¿cómo lo hago?", priorUserRequests: [])
        let draft = "Vivago permite generación 3D [B1]. Primero mide el consumo con una prueba pequeña."
        var repairs = 0
        let result = try await AssistantResearchAnswer.reviewAdvice(draft, plan: plan, spanish: true, sources: ["B1": source()]) { _ in
            repairs += 1; return .init(text: "No debería llamarse")
        }
        #expect(result.issues.isEmpty)
        #expect(result.text == draft)
        #expect(result.rounds == 0 && repairs == 0)
        #expect(!result.text.contains("## Interfaz"))
    }
    @Test("Repara una vez y descarta el texto inventado si persiste el fallo")
    @MainActor
    func boundsRepairAndPublication() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D", priorUserRequests: [])
        let bad = "Utiliza Modly [B1]. Esta estrategia ha sido validada por la documentación oficial."
        var repairs = 0
        let fixed = try await AssistantResearchAnswer.reviewAdvice(bad, plan: plan, spanish: true, sources: ["B1": source()]) { request in
            repairs += 1
            #expect(request.contains("Quiero optimizar generación 3D"))
            #expect(request.contains("página no leída"))
            return .init(text: "Vivago permite generación 3D [B1]. Conviene medir primero con una prueba pequeña.")
        }
        #expect(fixed.issues.isEmpty && repairs == 1 && fixed.rounds == 1)
        repairs = 0
        let refused = try await AssistantResearchAnswer.reviewAdvice(bad, plan: plan, spanish: true, sources: ["B1": source()]) { _ in repairs += 1; return .init(text: bad) }
        #expect(!refused.issues.isEmpty && repairs == 1)
        #expect(!refused.text.contains("Modly"))
        #expect(!refused.text.contains("ha sido validada"))
    }
    @Test("La cancelación tras reparación nunca publica su salida")
    @MainActor
    func cancellationPropagates() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D", priorUserRequests: [])
        let task = Task {
            try await AssistantResearchAnswer.reviewAdvice("Utiliza Modly [B1].", plan: plan, spanish: true, sources: ["B1": source()]) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(text: "Vivago permite generación 3D [B1].")
            }
        }
        do { _ = try await task.value; Issue.record("La cancelación debía propagarse") }
        catch is CancellationError { }
    }
}


extension GenericResearchReviewTests {
    @Test("La búsqueda y lectura posterior entra en el mismo mapa de citas")
    func incorporatesNewReadSource() {
        var registry = AssistantResearchTurnSources(["B1": source()])
        let new = AssistantLinkReference(title: "Modly", url: "https://example.org/modly", summary: "Modly genera modelos 3D.", collection: nil, tags: [], origin: .web)
        let answer = "Modly permite generar modelos 3D [W2]."
        #expect(!AssistantResearchAnswer.adviceIssues(in: answer, spanish: true, sources: registry.sources).isEmpty)
        #expect(registry.incorporate(.init("Resultado de búsqueda", references: [new])) == ["W2"])
        #expect(registry.sources["W2"]?.pageWasRead == false)
        let page = AssistantToolResult("Modly permite generar modelos 3D.", references: [new], didReadWebSource: true)
        #expect(registry.incorporate(page) == ["W2"])
        #expect(registry.sources["W2"]?.pageWasRead == true)
        #expect(registry.sources["B1"]?.pageWasRead == false)
        #expect(registry.context(ids: ["W2"], maximumCharacters: 900).contains("[W2]"))
        #expect(registry.context(ids: ["W2"], maximumCharacters: 900).contains("Modly permite"))
        #expect(AssistantResearchAnswer.adviceIssues(in: answer, spanish: true, sources: registry.sources).isEmpty)
        for unsupported in ["Utiliza Modly [W99].", "Modly es una base de datos SQL [W2].", "Esta estrategia ha sido validada por la documentación oficial [W2]."] {
            #expect(!AssistantResearchAnswer.adviceIssues(in: unsupported, spanish: true, sources: registry.sources).isEmpty)
        }
    }

    @Test("Alias estables, lecturas exactas y registro acotado")
    func stableAliasesAndReadReceipts() {
        var registry = AssistantResearchTurnSources(["B1": source(), "W7": source()])
        let same = AssistantLinkReference(title: "Vivago", url: "https://example.org/vivago", summary: nil, collection: nil, tags: [], origin: .web)
        #expect(registry.incorporate(.init("Vivago permite generación 3D.", references: [same], didReadWebSource: true)) == ["B1"])
        #expect(registry.sources["B1"]?.pageWasRead == true)
        #expect(registry.sources["W7"]?.pageWasRead == false)
        let others = (0..<70).map { AssistantLinkReference(title: "Recurso \($0)", url: "https://example.org/new/\($0)", summary: "Candidato", collection: nil, tags: [], origin: .web) }
        let ids = registry.incorporate(.init("Una lectura no acredita múltiples páginas", references: others, didReadWebSource: true))
        #expect(ids.first == "W8")
        #expect(registry.sources.count == AssistantResearchDossier.maximumSources)
        #expect(registry.sources["W8"]?.pageWasRead == false)
        #expect(registry.context(ids: ids, maximumCharacters: 900).count <= 900)
        #expect(registry.sources["B1"]?.evidence == "Vivago permite generación 3D.")
    }

    @Test("Una respuesta truncada se repara aunque sus citas sean válidas")
    @MainActor
    func rejectsTruncatedDraftAndRepair() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D", priorUserRequests: [])
        let valid = "Vivago permite generación 3D [B1]."
        var metrics: [AssistantResearchReviewMetrics] = []
        var repairs = 0
        let rejected = try await AssistantResearchAnswer.reviewAdvice(valid, plan: plan, spanish: true, sources: ["B1": source()], draftReachedLengthLimit: true, recordReview: { metrics.append($0) }) { _ in
            repairs += 1
            return .init(text: valid, reachedLengthLimit: true)
        }
        #expect(repairs == 1 && !rejected.issues.isEmpty)
        #expect(metrics.count == 2 && metrics.allSatisfy(\.reachedLengthLimit))
        #expect(metrics.allSatisfy { $0.unknownCitations == 0 && $0.sourceCount == 1 })
        #expect(rejected.text != valid)
        let repaired = try await AssistantResearchAnswer.reviewAdvice(valid, plan: plan, spanish: true, sources: ["B1": source()], draftReachedLengthLimit: true) { _ in .init(text: valid) }
        #expect(repaired.text == valid && repaired.issues.isEmpty)
    }
}

extension GenericResearchReviewTests {
    @Test("Los fragmentos locales posteriores no se reparten entre recursos")
    func keepsStructuredLocalEvidence() {
        var registry = AssistantResearchTurnSources(["B1": source()])
        let reference = AssistantLinkReference(title: "Modly", url: "https://example.org/modly", summary: "Candidato", collection: nil, tags: [], origin: .library)
        let local = AssistantResearchSource(title: "Modly", url: reference.url, bookmarkID: UUID(), summary: "Candidato", evidence: "Modly ofrece una base de datos SQL.", origin: .library, facets: [.overview], collection: nil, tags: [])
        let other = AssistantResearchSource(title: "Otro recurso", url: "https://example.org/other", bookmarkID: nil, summary: "Otro", evidence: "No corresponde a esta referencia", origin: .library, facets: [.overview], collection: nil, tags: [])
        _ = registry.incorporate(.init("Texto agregado sin autoridad", references: [reference], researchSources: [local, other]))
        #expect(registry.sources["B2"]?.evidence == local.evidence)
        #expect(registry.sources["B2"]?.pageWasRead == false)
        #expect(registry.sources.count == 2)
        #expect(registry.sources["B1"]?.evidence.isEmpty == true)
        #expect(AssistantResearchAnswer.adviceIssues(in: "Modly ofrece una base de datos SQL [B2].", spanish: true, sources: registry.sources).isEmpty)
        var enriched = local
        enriched.summary = String(repeating: "Resumen más rico. ", count: 110)
        _ = registry.incorporate(.init("", references: [reference], researchSources: [enriched]))
        #expect(registry.sources["B2"]?.summary == String(enriched.summary.prefix(1_800)))
        #expect(registry.sources["B2"]?.evidence == local.evidence)
    }

    @Test("Si la reparación falla muestra candidatos del tema sin publicar instrucciones inventadas")
    @MainActor
    func recoversUsefulSourceInformation() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D local", priorUserRequests: [])
        let geometry = AssistantResearchSource(title: "Modly", url: "https://example.org/modly", bookmarkID: nil,
            summary: "Generación 3D local a partir de imágenes. Fuente [W999] y (B99).", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        let irrelevant = AssistantResearchSource(title: "Servidor SQL", url: "https://example.org/sql", bookmarkID: nil,
            summary: "Base de datos relacional.", evidence: "", origin: .web, facets: [.database], collection: nil, tags: [])
        let bad = "Utiliza QuantumMesh3D [B1]. Ejecuta --comando-inventado."
        let result = try await AssistantResearchAnswer.reviewAdvice(bad, plan: plan, spanish: true, sources: ["B1": geometry, "W2": irrelevant]) { _ in .init(text: bad) }
        #expect(!result.issues.isEmpty)
        #expect(result.text.contains("[B1] «Modly»"))
        #expect(result.text.contains("página no leída"))
        #expect(result.text.contains("Descripción de la ficha"))
        #expect(result.text.contains("Cambia una sola opción documentada"))
        #expect(!result.text.contains("QuantumMesh3D") && !result.text.contains("--comando-inventado") && !result.text.contains("Servidor SQL"))
        #expect(AssistantResearchAnswer.citationTokens(in: result.text) == ["B1"])
    }

    @Test("La reparación conserva primero el tema aunque el borrador cite una guía ajena")
    @MainActor
    func prioritizesRelevantRepairEvidence() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D local con IA", priorUserRequests: [])
        let general = AssistantResearchSource(title: "Inferencia de lenguaje", url: "https://example.org/language", bookmarkID: nil,
            summary: String(repeating: "Memoria de modelos de texto. ", count: 100), evidence: String(repeating: "Página leída. ", count: 200),
            origin: .web, facets: [.overview], pageWasRead: true, collection: nil, tags: [])
        let geometry = AssistantResearchSource(title: "Modly", url: "https://example.org/modly", bookmarkID: nil,
            summary: "Modly genera modelos 3D localmente.", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        _ = try await AssistantResearchAnswer.reviewAdvice("Utiliza HerramientaInventada [W1].", plan: plan, spanish: true,
                sources: ["W1": general, "B64": geometry], contextWindow: 8_192) { request in
            let relevant = request.range(of: "[B64] Modly")!
            let unrelated = request.range(of: "[W1] Inferencia de lenguaje")!
            #expect(relevant.lowerBound < unrelated.lowerBound)
            return .init(text: "Modly es un candidato para generar modelos 3D [B64]. Primero mide el consumo con una prueba pequeña.")
        }
    }

    @Test("La reparación reserva pensamiento y respuesta dentro de 8K con dossier lleno")
    @MainActor
    func boundsJointRepairContext() async throws {
        let plan = AssistantResearchPlan.make(request: "Quiero optimizar generación 3D", priorUserRequests: [])
        let many = Dictionary(uniqueKeysWithValues: (1...64).map { index in
            ("B\(index)", AssistantResearchSource(title: "Vivago", url: "https://example.org/vivago/\(index)", bookmarkID: nil,
                summary: String(repeating: "Metadatos 😊漢字 ", count: 150), evidence: String(repeating: "Evidencia 😊漢字 ", count: 180),
                origin: .library, facets: [.overview], pageWasRead: index == 64, collection: nil, tags: []))
        })
        let invalid = "Utiliza Modly [B64]. " + String(repeating: "BORRADOR 😊漢字 ", count: 500)
        let result = try await AssistantResearchAnswer.reviewAdvice(invalid, plan: plan, spanish: true, sources: many, contextWindow: 8_192) { request in
            let generation = AssistantSessionPolicy.reasonedGenerationTokens(answerTokens: AssistantContextBudget.outputTokens(contextWindow: 8_192))
            #expect(request.utf8.count + generation + 1_024 <= 8_192)
            #expect(request.contains("[B64]"))
            #expect(request.contains("página leída"))
            #expect(request.components(separatedBy: "[FIN_DATOS_NO_CONFIABLES]").count == 3)
            return .init(text: "Conviene medir primero con una prueba pequeña y registrar el consumo de memoria.")
        }
        #expect(result.issues.isEmpty && result.rounds == 1)
    }
}

extension GenericResearchReviewTests {
    @Test("Los rótulos de una fuente y el término dimensional no son afirmaciones de producto")
    func sourceLabelsAndDimensionalProse() {
        let modly = AssistantResearchSource(title: "Modly", url: "https://example.org/modly", bookmarkID: nil,
            summary: "Modly genera modelos 3D localmente.", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        let text = "### Modly\nModly es un candidato para generar modelos 3D [B1].\nEs un punto de partida 3D.\nEl contexto de inferencia no es de 3D."
        #expect(AssistantResearchAnswer.adviceIssues(in: text, spanish: true, sources: ["B1": modly]).isEmpty)
        #expect(!AssistantResearchAnswer.adviceIssues(in: "### Modly ofrece SQL [B1]", spanish: true, sources: ["B1": modly]).isEmpty)
        #expect(!AssistantResearchAnswer.adviceIssues(in: "### QuantumMesh3D\nModly genera modelos [B1].", spanish: true, sources: ["B1": modly]).isEmpty)
    }

    @Test("Las dimensiones y medidas no se confunden con identidades de productos")
    func measurementsAreNotProductNames() {
        let modly = AssistantResearchSource(title: "Modly: Local AI 3D Model Generator for Desktop", url: "https://example.org/modly", bookmarkID: nil,
            summary: "Modly genera modelos 3D localmente.", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        let valid = """
        Modly es un candidato para generar modelos 3D [B1].
        Primero registra el consumo con una prueba 3D pequeña.
        En un Mac con 16GB de RAM, mide el consumo máximo y el tiempo.
        Compara una entrada 512x512 con otra de mayor resolución.
        """
        let issues = AssistantResearchAnswer.adviceIssues(in: valid, spanish: true, sources: ["B1": modly])
        #expect(issues.isEmpty)
        let plain = AssistantResearchSource(title: "Modly", url: "https://example.org/modly", bookmarkID: nil,
            summary: "Genera modelos localmente.", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        for name in ["QuantumMesh3D", "3DTool", "Python3.14", "3D", "16GB", "512x512"] {
            #expect(!AssistantResearchAnswer.adviceIssues(in: "Utiliza \(name) [B1].", spanish: true, sources: ["B1": plain]).isEmpty)
        }
        for introduction in ["herramienta", "motor", "framework", "app", "aplicación", "tool", "engine", "application"] {
            #expect(!AssistantResearchAnswer.adviceIssues(in: "La \(introduction) 3D es candidata [B1].", spanish: true, sources: ["B1": plain]).isEmpty)
        }
        #expect(!AssistantResearchAnswer.adviceIssues(in: "Backend: 3D gestiona usuarios [B1].", spanish: true, sources: ["B1": plain]).isEmpty)
        #expect(!AssistantResearchAnswer.adviceIssues(in: "La herramienta «512x512» procesa la imagen [B1].", spanish: true, sources: ["B1": modly]).isEmpty)
        for invalid in ["La herramienta 512x512 procesa la imagen [B1].", "512x512. Mide el consumo.", "Una entrada 512x512 y la herramienta 512x512 procesa la imagen [B1]."] {
            #expect(!AssistantResearchAnswer.adviceIssues(in: invalid, spanish: true, sources: ["B1": modly]).isEmpty)
        }
        let unrelated = AssistantResearchSource(title: "Otra herramienta", url: "https://example.org/unrelated", bookmarkID: nil,
            summary: "Requiere 16GB de RAM y una entrada 512x512.", evidence: "", origin: .library, facets: [.overview], collection: nil, tags: [])
        #expect(AssistantResearchAnswer.adviceIssues(in: valid, spanish: true, sources: ["B1": modly, "B2": unrelated]).isEmpty)
    }
}
