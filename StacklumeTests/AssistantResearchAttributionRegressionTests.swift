import Foundation
import Testing

@Suite("JD Chat corrección1: contratos checker y Composer", .serialized)
struct JDFix1Tests {
    func source(_ title: String, _ summary: String, _ facet: AssistantResearchFacet = .engine) -> AssistantResearchSource {
        .init(title: title, url: "https://fixture.invalid/" + title, bookmarkID: nil, summary: summary, evidence: "", origin: .library, facets: [facet], collection: nil, tags: [])
    }
    var records: [String: AssistantResearchSource] {
        ["B1": source("ApiOne", "ApiOne implementa backend mediante una API REST. Permite exportación JSON."),
         "B2": source("SoapEngine", "SoapEngine implementa backend mediante una API SOAP. Permite exportación CSV."),
         "B3": source("DataStore", "DataStore conserva una base de datos SQL. Permite exportación CSV.", .database)]
    }
    func check(_ text: String, records: [String: AssistantResearchSource]? = nil, defaults: Set<String> = ["B2"]) -> [String] {
        let sources = records ?? self.records
        return AssistantResearchAnswer.structuredCapabilityIssues(in: text, defaultSubjectIDs: defaults, allowedIDs: Set(sources.keys), sources: sources)
    }
    func publishes(_ result: AssistantResearchComposition, _ text: String) -> Bool {
        Data(result.text.utf8).range(of: Data(text.utf8)) != nil
    }
    func emit(_ value: [String: Any]) {
        print("JD_FIX1_JSON", String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    }
    @MainActor
    func compose(_ text: String, field: String, spanish: Bool = true, records: [String: AssistantResearchSource]? = nil) async throws -> AssistantResearchComposition {
        let sources = records ?? self.records
        let one = sources["B1"]!.title, two = sources["B2"]!.title, data = sources["B3"]!.title
        var dossier = AssistantResearchDossier()
        dossier.append(.init(sources: [sources["B1"]!, sources["B2"]!, sources["B3"]!], candidateCount: 3), query: .init(facet: .engine, text: "backend"), web: false)
        let plan = AssistantResearchPlan.make(request: spanish ? "Quiero crear una app con backend y base de datos." : "I want to build an app with a backend and database.", priorUserRequests: [])
        return try await AssistantResearchComposer.compose(plan: plan, dossier: dossier, spanish: spanish, outputTokens: 4096) { round in
            let indexed = Dictionary(uniqueKeysWithValues: dossier.indexedSources)
            func alias(_ role: String, _ title: String) -> String { round.sourceAliasesByRole[role]!.first { indexed[$0.value]?.title == title }!.key }
            var rows: [[String: Any]] = []
            if round.sourceAliasesByRole["engine"] != nil { rows.append(
                ["roleID": "engine", "choiceSourceID": alias("engine", one), "alternativeSourceID": alias("engine", two),
                 "fit": spanish ? one + " implementa una API " + (one == "Vue" ? "SOAP." : "REST.") : one + " implements a REST API.",
                 "difference": field == "difference" ? text : (spanish ? two + " implementa una API " + (one == "Vue" ? "REST." : "SOAP.") : two + " implements a SOAP API."),
                 "verification": spanish ? "Comprobar las políticas de acceso antes de publicar." : "Check the access policies before publishing."]) }
            if round.sourceAliasesByRole["database"] != nil { rows.append(
                ["roleID": "database", "choiceSourceID": alias("database", data), "alternativeSourceID": NSNull(),
                 "fit": spanish ? "Conserva los datos estructurados del programa." : "Stores the structured data for the application.",
                 "difference": spanish ? "Alternativa provisional sin respaldo de fuentes; falta precisar la operación del programa." : "Provisional alternative without sources; the application operation still needs clarification.",
                 "verification": spanish ? "Comprobar las políticas de acceso antes de publicar." : "Check the access policies before publishing."]) }
            return String(data: try JSONSerialization.data(withJSONObject: ["components": rows, "integration": field == "integration" ? text : (spanish ? "La API elegida accede a la base de datos del programa." : "The selected API accesses the application database.")]), encoding: .utf8)!
        }
    }
    @Test("H1: cada predicado parentético conserva su propietario explícito")
    @MainActor
    func parentheticalCoordination() async throws {
        let cases: [(String, Bool, Bool)] = [
            ("ApiOne implementa una API REST (ApiOne permite exportación CSV y SoapEngine permite exportación CSV).", false, true),
            ("ApiOne implementa una API REST (ApiOne permite exportación JSON y SoapEngine permite exportación CSV).", true, true),
            ("ApiOne implementa una API REST (SoapEngine permite exportación JSON y ApiOne permite exportación JSON). Además permite exportación JSON.", false, true),
            ("ApiOne implementa una API REST (SoapEngine permite exportación CSV y ApiOne permite exportación JSON). Además permite exportación JSON.", true, true),
            ("ApiOne implementa una API REST (SoapEngine permite exportación JSON, pero ApiOne permite exportación JSON).", false, true),
            ("ApiOne implementa una API REST (SoapEngine permite exportación CSV, pero ApiOne permite exportación JSON).", true, true),
            ("ApiOne implements a REST API (ApiOne allows CSV export and SoapEngine allows CSV export).", false, false),
            ("ApiOne implements a REST API (ApiOne allows JSON export and SoapEngine allows CSV export).", true, false)]
        for (text, supported, spanish) in cases {
            let issues = check(text)
            #expect(issues.isEmpty == supported, Comment(rawValue: text))
            for field in ["difference", "integration"] {
                let result = try await compose(text, field: field, spanish: spanish)
                emit(["finding": "H1", "field": field, "text": text, "supported": supported, "issues": result.issues, "rounds": result.rounds, "published": publishes(result, text)])
                #expect(publishes(result, text) == supported, Comment(rawValue: field + ": " + text))
                if supported { #expect(result.issues.isEmpty); #expect(result.rounds == 1) }
                else { #expect(!result.issues.isEmpty); #expect(result.rounds == 2) }
            }
        }
    }
}

extension JDFix1Tests {
    @Test("H2: el predicado parentético elíptico conserva el descriptor completo")
    @MainActor
    func implicitParenthetical() async throws {
        for spanish in [true, false] {
            for (format, supported) in [("CSV", false), ("JSON", true)] {
                let text = spanish ? "ApiOne implementa una API REST (permite exportación " + format + ")." : "ApiOne implements a REST API (allows " + format + " export)."
                for defaults: Set<String> in [[], ["B1"], ["B2"]] {
                    #expect(check(text, defaults: defaults).isEmpty == supported, Comment(rawValue: text))
                }
                for field in ["difference", "integration"] {
                    let result = try await compose(text, field: field, spanish: spanish)
                    emit(["finding": "H2", "field": field, "text": text, "supported": supported, "issues": result.issues, "rounds": result.rounds, "published": publishes(result, text)])
                    #expect(publishes(result, text) == supported)
                    if supported { #expect(result.issues.isEmpty); #expect(result.rounds == 1) }
                    else { #expect(!result.issues.isEmpty); #expect(result.rounds == 2) }
                }
            }
        }
    }
}

extension JDFix1Tests {
    @Test("H3: identidad corta explícita prevalece sobre default y conjunto vacío")
    @MainActor
    func shortIdentity() async throws {
        let sources = ["B1": source("Vue", "Vue implementa backend mediante una API SOAP."),
                       "B2": source("RestEngine", "RestEngine implementa backend mediante una API REST."),
                       "B3": records["B3"]!]
        for name in ["Vue", "«Vue»", "Ｖｕｅ", "Vué"] {
            for (protocolName, supported) in [("REST", false), ("SOAP", true)] {
                let text = name + " implementa una API " + protocolName + "."
                for defaults: Set<String> in [[], ["B1"], ["B2"]] {
                    #expect(check(text, records: sources, defaults: defaults).isEmpty == supported, Comment(rawValue: text))
                    let field = AssistantResearchAnswer.capabilityField(in: text, defaultSubjectIDs: defaults, allowedIDs: Set(sources.keys), sources: sources)
                    #expect(!field.obligations.isEmpty)
                    #expect(field.obligations.allSatisfy { $0.owners == ["B1"] })
                }
                for field in ["difference", "integration"] {
                    let result = try await compose(text, field: field, records: sources)
                    emit(["finding": "H3", "field": field, "text": text, "supported": supported, "issues": result.issues, "rounds": result.rounds, "published": publishes(result, text)])
                    #expect(publishes(result, text) == supported)
                    if supported { #expect(result.issues.isEmpty); #expect(result.rounds == 1) }
                    else { #expect(!result.issues.isEmpty); #expect(result.rounds == 2) }
                }
            }
        }
        let bounded = AssistantResearchAnswer.capabilityField(in: "Vuex implementa una API REST.", defaultSubjectIDs: ["B2"], allowedIDs: Set(sources.keys), sources: sources)
        #expect(bounded.obligations.allSatisfy { !$0.owners.contains("B1") })
        #expect(check("Ofrece una API REST.", records: sources, defaults: ["B2"]).isEmpty)
        #expect(!check("Ofrece una API REST.", records: sources, defaults: ["B1"]).isEmpty)
    }
}

extension JDFix1Tests {
    @Test("H4: él y ella preservan incertidumbre tras finalidad; el artículo no es pronombre")
    @MainActor
    func pronounUncertainty() async throws {
        for pronoun in ["ella", "él", "ÉL", "e\u{301}l", "este"] {
            for format in ["JSON", "CSV"] {
                let text = "ApiOne ofrece una API para que DataStore consulte una base de datos SQL, pero " + pronoun + " también permite exportación " + format + "."
                let issues = check(text)
                #expect(issues.contains { $0.contains("indeterminado") }, Comment(rawValue: text))
                let field = AssistantResearchAnswer.capabilityField(in: text, defaultSubjectIDs: ["B1"], allowedIDs: Set(records.keys), sources: records)
                #expect(field.obligations.isEmpty)
            }
            for field in ["difference", "integration"] {
                let target = field == "difference" ? "SoapEngine" : "DataStore"
                let text = "ApiOne ofrece una API para que " + target + " consulte una base de datos SQL, pero " + pronoun + " también permite exportación JSON."
                let result = try await compose(text, field: field)
                emit(["finding": "H4", "field": field, "text": text, "issues": result.issues, "rounds": result.rounds, "published": publishes(result, text)])
                #expect(!publishes(result, text))
                #expect(result.issues.contains { $0.contains("indeterminado") })
                #expect(result.rounds == 2)
            }
        }
        let english = "ApiOne offers an API for DataStore to query a SQL database, but it also exports JSON."
        #expect(check(english).contains { $0.contains("indeterminado") })
        let unresolved = try await compose(english, field: "integration", spanish: false)
        #expect(!publishes(unresolved, english))
        #expect(unresolved.issues.contains { $0.contains("indeterminado") })
        for (text, supported) in [
            ("ApiOne ofrece una API para que DataStore consulte una base de datos SQL, pero ApiOne permite exportación JSON.", true),
            ("ApiOne ofrece una API para que DataStore consulte una base de datos SQL, pero el DataStore permite exportación CSV.", true),
            ("ApiOne ofrece una API para que DataStore consulte una base de datos SQL, pero el DataStore permite exportación JSON.", false),
            ("ApiOne implementa una API REST. Ella permite exportación JSON.", true),
            ("ApiOne implementa una API REST. Él permite exportación CSV.", false)] {
            #expect(check(text).isEmpty == supported, Comment(rawValue: text))
            let result = try await compose(text, field: "integration")
            #expect(publishes(result, text) == supported)
            if supported { #expect(result.issues.isEmpty); #expect(result.rounds == 1) }
        }
    }
}

extension JDFix1Tests {
    @Test("H5: los checks admitidos se ejecutan fuera de MainActor y la generación permanece aislada")
    @MainActor
    func concurrentValidationHeartbeat() async throws {
        for iteration in 0..<5 {
            var heartbeat: Task<Double, Never>?
            var heartbeatStarted = false
            var dossier = AssistantResearchDossier()
            let sources = records
            dossier.append(.init(sources: [sources["B1"]!, sources["B2"]!, sources["B3"]!], candidateCount: 3), query: .init(facet: .engine, text: "backend"), web: false)
            let plan = AssistantResearchPlan.make(request: "Quiero crear una app con backend y base de datos.", priorUserRequests: [])
            let fit = "ApiOne implementa una API " + String(repeating: "(REST)", count: 161) + "."
            let difference = "SoapEngine implementa una API " + String(repeating: "(SOAP)", count: 160) + "."
            let integration = "ApiOne implementa una API " + String(repeating: "(REST)", count: 240) + "."
            #expect(fit.count <= 1000 && difference.count <= 1000 && integration.count <= 1500)
            let start = ContinuousClock.now
            let result = try await AssistantResearchComposer.compose(plan: plan, dossier: dossier, spanish: true, outputTokens: 4096,
                detectedLanguage: { _ in #expect(!Thread.isMainThread); return "es" }) { round in
                MainActor.preconditionIsolated()
                if heartbeat == nil {
                    heartbeat = Task { @MainActor in
                        heartbeatStarted = true
                        let began = ContinuousClock.now
                        try? await Task.sleep(for: .milliseconds(10))
                        let elapsed = began.duration(to: .now)
                        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                    }
                    while !heartbeatStarted { await Task.yield() }
                }
                let indexed = Dictionary(uniqueKeysWithValues: dossier.indexedSources)
                func alias(_ role: String, _ title: String) -> String { round.sourceAliasesByRole[role]!.first { indexed[$0.value]?.title == title }!.key }
                let rows: [[String: Any]] = [
                    ["roleID": "engine", "choiceSourceID": alias("engine", "ApiOne"), "alternativeSourceID": alias("engine", "SoapEngine"), "fit": fit, "difference": difference, "verification": "Comprobar las políticas de acceso antes de publicar."],
                    ["roleID": "database", "choiceSourceID": alias("database", "DataStore"), "alternativeSourceID": NSNull(), "fit": "Conserva los datos estructurados del programa.", "difference": "Alternativa provisional sin respaldo de fuentes; falta precisar la operación del programa.", "verification": "Comprobar las políticas de acceso antes de publicar."]]
                return String(data: try JSONSerialization.data(withJSONObject: ["components": rows, "integration": integration]), encoding: .utf8)!
            }
            let elapsed = start.duration(to: .now)
            #expect(result.issues.isEmpty)
            #expect(result.rounds == 1)
            let heartbeatMilliseconds = await heartbeat!.value
            emit(["finding": "H5", "iteration": iteration, "heartbeatMilliseconds": heartbeatMilliseconds,
                  "composeMilliseconds": Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                  "lengths": [fit.count, difference.count, integration.count], "issues": result.issues, "rounds": result.rounds])
        }
    }
}

extension JDFix1Tests {
    @Test("Presupuestos globales32/256: dominios parentéticos cuentan por predicación")
    func fieldBudgets() {
        let cases: [(String, String, Bool)] = [
            ("profundidad32", "ApiOne implementa una API " + String(repeating: "(", count: 32) + "REST" + String(repeating: ")", count: 32) + ".", true),
            ("profundidad33", "ApiOne implementa una API " + String(repeating: "(", count: 33) + "REST" + String(repeating: ")", count: 33) + ".", false),
            ("grupos256", "ApiOne implementa una API " + String(repeating: "(REST)", count: 256) + ".", true),
            ("grupos257", "ApiOne implementa una API " + String(repeating: "(REST)", count: 257) + ".", false),
            ("dominios256", String(repeating: "ApiOne implementa una API REST. ", count: 256), true),
            ("dominios257", String(repeating: "ApiOne implementa una API REST. ", count: 257), false),
            ("parentéticos255+principal", "ApiOne implementa una API REST (" + Array(repeating: "ApiOne permite exportación JSON", count: 255).joined(separator: " y ") + ").", true),
            ("parentéticos256+principal", "ApiOne implementa una API REST (" + Array(repeating: "ApiOne permite exportación JSON", count: 256).joined(separator: " y ") + ").", false)]
        for (label, text, accepted) in cases {
            let issues = check(text)
            emit(["finding": "presupuesto", "id": label, "issues": issues, "accepted": accepted])
            #expect(issues.isEmpty == accepted, Comment(rawValue: label))
            if !accepted { #expect(issues.contains { $0.contains("256") || $0.contains("32") }) }
        }
    }
}
