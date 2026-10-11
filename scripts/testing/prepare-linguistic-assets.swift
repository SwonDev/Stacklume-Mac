import Foundation
import NaturalLanguage

func log(_ values: Any...) {
    let line = values.map { String(describing: $0) }.joined(separator: " ") + "\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

final class AssetRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (Int, String?)?

    func finish(_ result: NLTagger.AssetsResult, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        storage = (result.rawValue, error?.localizedDescription)
    }

    var value: (Int, String?)? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

let deadline = ProcessInfo.processInfo.systemUptime + 120
let probeOnly = CommandLine.arguments.contains("--probe-only")
let downloadModels = CommandLine.arguments.contains("--download-models")
let requiredSchemes: [NLTagScheme] = downloadModels ? [.lexicalClass, .nameType] : [.lexicalClass, .lemma, .nameType]
for language in ["auto", "es", "en"] {
    for (context, word) in [("Propuesta: Comprobar la latencia.", "Comprobar"), ("Propuesta: Arquitectura basada en FastAPI.", "Arquitectura"), ("Propuesta: Puedes utilizar FastAPI para usuarios y API.", "Puedes")] {
        let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass, .lemma, .nameType], options: 0)
        tagger.string = context
        if language != "auto" {
            tagger.setOrthography(NSOrthography.defaultOrthography(forLanguage: language), range: NSRange(context.startIndex..., in: context))
        }
        let range = (context as NSString).range(of: word)
        log("Diagnóstico inicial", language, word, "idioma", tagger.dominantLanguage ?? "nil", "clase", tagger.tag(at: range.location, unit: .word, scheme: .lexicalClass, tokenRange: nil)?.rawValue ?? "nil", "lema", tagger.tag(at: range.location, unit: .word, scheme: .lemma, tokenRange: nil)?.rawValue ?? "nil")
    }
}
for language in [NLLanguage.spanish, .english] {
    log("Esquemas iniciales \(language.rawValue):", NLTagger.availableTagSchemes(for: .word, language: language).map(\.rawValue))
    for scheme in requiredSchemes where !probeOnly && !NLTagger.availableTagSchemes(for: .word, language: language).contains(scheme) {
        let request = AssetRequestResult()
        NLTagger.requestAssets(for: language, tagScheme: scheme) { result, error in
            request.finish(result, error: error)
        }
        while request.value == nil && ProcessInfo.processInfo.systemUptime < deadline {
            if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {
                Thread.sleep(forTimeInterval: min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
        }
        guard let result = request.value, result.0 == NLTagger.AssetsResult.available.rawValue, result.1 == nil else {
            fatalError("Activos lingüísticos no disponibles: \(language.rawValue)/\(scheme.rawValue): \(String(describing: request.value))")
        }
        log("Activos disponibles: \(language.rawValue)/\(scheme.rawValue)")
    }
    let available = NLTagger.availableTagSchemes(for: .word, language: language)
    log("Esquemas finales \(language.rawValue):", available.map(\.rawValue))
    guard requiredSchemes.allSatisfy(available.contains) else {
        fatalError("El framework no ofrece todos los esquemas requeridos para \(language.rawValue).")
    }
}
if downloadModels {
    log("Modelos gramaticales y de entidades preparados; falta verificar los tres esquemas y las sondas en un proceso nuevo.")
    exit(0)
}

log("Idiomas preferidos:", Locale.preferredLanguages, "Locale:", Locale.current.identifier)
let probes: [(String, String, Set<NSLinguisticTag>)] = [
    ("Propuesta: Puedes utilizar FastAPI para usuarios y API.", "Puedes", [.verb]),
    ("Propuesta: Comprobar la latencia.", "Comprobar", [.verb]),
    ("Propuesta: Recomendado para usuarios y API.", "Recomendado", [.verb, .adjective]),
    ("Propuesta: Arquitectura basada en FastAPI.", "Arquitectura", [.noun]),
    ("Propuesta: Arquitectura basada en FastAPI.", "basada", [.adjective])
]
for (context, word, expected) in probes {
    let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass, .lemma, .nameType], options: 0)
    tagger.string = context
    let range = (context as NSString).range(of: word)
    let actual = tagger.tag(at: range.location, unit: .word, scheme: .lexicalClass, tokenRange: nil)
    let lemma = tagger.tag(at: range.location, unit: .word, scheme: .lemma, tokenRange: nil)
    log("Sonda \(word): \(actual?.rawValue ?? "nil"), esperado \(expected.map(\.rawValue).sorted())")
    guard let actual, expected.contains(actual) else {
        fatalError("El runner no satisface la dependencia lingüística usada por el validador; no se omiten sus tests.")
    }
    if word == "Arquitectura", lemma == nil {
        fatalError("Falta el lema del sustantivo usado por el validador.")
    }
}
log("Dependencias lingüísticas verificadas.")
