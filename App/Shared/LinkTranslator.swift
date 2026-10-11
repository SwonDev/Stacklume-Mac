import Foundation
import SwiftData
import NaturalLanguage
import StacklumeCore

/// Traduce al idioma de la app los textos de un enlace (título, descripción, resumen) que
/// estén en un idioma que el usuario NO entiende: cualquiera que NO sea inglés ni español.
/// El inglés y el español se dejan INTACTOS. Detección inteligente: script no latino
/// (chino/japonés/coreano/cirílico/árabe…) → siempre extranjero; script latino → se decide
/// con `NLLanguageRecognizer` de Apple. La traducción usa el framework `Translation` ON-DEVICE
/// de Apple (`TranslationSession`), fiable y hecho para esto (el LLM de generación ecoaba el
/// original). 100 % local. Así toda la biblioteca se entiende a la perfección.
@MainActor
enum LinkTranslator {

    /// ¿Algún texto del enlace necesita traducción a español por la RED DE SEGURIDAD de Apple?
    /// Deliberadamente CONSERVADOR para no desatar una cascada de descargas de idiomas ni
    /// re-traducir lo que ya está bien: el grueso lo hace la IA (regenera en español desde
    /// cualquier idioma). Aquí solo se traduce lo que se detecta CON FIABILIDAD:
    /// - Títulos: solo script NO latino (chino/japonés/árabe…). Nombres en inglés se respetan.
    /// - Descripciones: script no latino, o INGLÉS real (el caso cuando el LLM «ecoa» el original).
    /// NO «cualquier idioma que no sea español»: `NLLanguageRecognizer` confunde español/jerga con
    /// italiano/portugués/indonesio/polaco y eso pedía un paquete por idioma falso y destrozaba
    /// descripciones ya correctas.
    static func needsTranslation(_ link: Bookmark) -> Bool {
        isForeign(link.title)
            || isTranslatableDescription(link.details ?? "")
            || isTranslatableDescription(link.summary ?? "")
    }

    /// Identificador BCP-47 del idioma de ORIGEN del contenido a traducir (p. ej. «en», «zh-Hans»,
    /// «ja»), para configurar la `TranslationSession`. `nil` si no se detecta.
    static func sourceIdentifier(for link: Bookmark) -> String? {
        if isForeign(link.title) {
            // CLAVE: el idioma de origen se decide por el SCRIPT no latino (chino/japonés/…), NO
            // por `NLLanguageRecognizer`. En títulos MIXTOS («owner/repo: 中文…», muy comunes en
            // GitHub) el reconocedor se confunde con el ruido latino y devolvía «inglés» → la sesión
            // se configuraba `en→es` y el chino NO se traducía. Por script es inequívoco.
            if let lang = scriptLanguage(link.title) { return lang }
            if let language = detectLanguage(link.title) { return language.rawValue }
        }
        for field in [link.details ?? "", link.summary ?? ""] where isTranslatableDescription(field) {
            if let lang = scriptLanguage(field) { return lang }   // script no latino → por script
            // El inglés se fija explícito (evita que una detección dudosa lo mande a otro par).
            if isEnglish(field) { return NLLanguage.english.rawValue }
            if let language = detectLanguage(field) { return language.rawValue }
        }
        return nil
    }

    /// Identificador BCP-47 del idioma según el SCRIPT no latino PREDOMINANTE del texto, o `nil`
    /// si no hay script no latino. Determinista y robusto ante textos MIXTOS (latino + CJK), donde
    /// el reconocedor de Apple falla. Distingue japonés (tiene kana) de chino (solo Han).
    static func scriptLanguage(_ text: String) -> String? {
        var hasKana = false, hasHangul = false, hasHan = false, hasCyrillic = false
        var hasArabic = false, hasHebrew = false, hasThai = false, hasGreek = false, hasDevanagari = false
        for s in text.unicodeScalars {
            let v = s.value
            if (0x3040...0x30FF).contains(v) { hasKana = true }
            else if (0xAC00...0xD7AF).contains(v) { hasHangul = true }
            else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { hasHan = true }
            else if (0x0400...0x04FF).contains(v) { hasCyrillic = true }
            else if (0x0600...0x06FF).contains(v) { hasArabic = true }
            else if (0x0590...0x05FF).contains(v) { hasHebrew = true }
            else if (0x0E00...0x0E7F).contains(v) { hasThai = true }
            else if (0x0370...0x03FF).contains(v) { hasGreek = true }
            else if (0x0900...0x097F).contains(v) { hasDevanagari = true }
        }
        if hasKana { return "ja" }            // kana ⇒ japonés (aunque mezcle kanji)
        if hasHangul { return "ko" }
        if hasHan { return "zh-Hans" }        // Han sin kana ⇒ chino
        if hasCyrillic { return "ru" }
        if hasArabic { return "ar" }
        if hasHebrew { return "he" }
        if hasThai { return "th" }
        if hasGreek { return "el" }
        if hasDevanagari { return "hi" }
        return nil
    }

    /// ¿La descripción es traducible CON FIABILIDAD por la red de seguridad? Script no latino, o
    /// inglés real. (Distinto de `isForeignDescription`, que es más amplio y lo usa la IA para
    /// decidir qué REGENERAR en español, sin riesgo de cascada porque la IA es local.)
    static func isTranslatableDescription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 30 else { return false }
        return hasNonLatinScript(trimmed) || isEnglish(trimmed)
    }

    /// ¿El texto está claramente en INGLÉS? Dominante inglés con peso alto (≥0.65): así NO casa con
    /// español ni con las confusiones del reconocedor (it/pt/id/pl) sobre texto técnico.
    nonisolated static func isEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard recognizer.dominantLanguage == .english else { return false }
        return (recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0) >= 0.65
    }

    // La traducción en sí la hace el lote de Mantenimiento dentro del closure no-aislado de
    // `.translationTask` (la `TranslationSession` de Swift 6 no puede cruzar a métodos
    // `@MainActor`): este tipo solo aporta la DETECCIÓN de qué traducir y a qué idioma.

    // MARK: - Detección

    /// `true` si el texto está en un idioma de SCRIPT NO LATINO (chino, japonés, coreano,
    /// cirílico, árabe, hebreo, tailandés, griego, devanagari…) → hay que traducirlo. Se
    /// limita a scripts no latinos PORQUE es detección 100 % inequívoca (sin falsos
    /// positivos): el reconocedor de idioma de Apple confunde títulos cortos en inglés/
    /// español/portugués/italiano y traduciría por error textos que el usuario ya entiende.
    /// Inglés y español (y demás escritura latina) se dejan INTACTOS.
    static func isForeign(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return hasNonLatinScript(trimmed)
    }

    /// ¿La DESCRIPCIÓN está en un idioma que NO es español? A diferencia de los títulos (cortos
    /// y ambiguos), una descripción es texto largo donde `NLLanguageRecognizer` SÍ es fiable, así
    /// que aquí sí se detecta el inglés (y cualquier otro) para traducirlo a español. Conservador:
    /// exige un mínimo de texto y, en script latino, que el español NO sea el idioma dominante ni
    /// una hipótesis con peso (evita falsos positivos en frases cortas o mezcladas).
    static func isForeignDescription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 30 else { return false }   // poco texto → no fiarse
        if hasNonLatinScript(trimmed) { return true }
        return !isSpanish(trimmed)
    }

    /// ¿El texto está en español? Dominante español, o español entre las hipótesis con peso
    /// suficiente (tolera la confusión es/pt/gl/ca sin traducir de más).
    static func isSpanish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if recognizer.dominantLanguage == .spanish { return true }
        return (recognizer.languageHypotheses(withMaximum: 3)[.spanish] ?? 0) >= 0.40
    }

    nonisolated static func detectLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// ¿El texto contiene caracteres de scripts NO latinos? (chino, japonés, coreano,
    /// cirílico, árabe, hebreo, tailandés, griego, devanagari…).
    private static func hasNonLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { isNonLatinScalar($0.value) }
    }

    private static func isNonLatinScalar(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v)      // CJK Unificado
            || (0x3400...0x4DBF).contains(v)  // CJK Ext A
            || (0x3040...0x30FF).contains(v)  // Hiragana + Katakana
            || (0xAC00...0xD7AF).contains(v)  // Hangul
            || (0x0400...0x04FF).contains(v)  // Cirílico
            || (0x0600...0x06FF).contains(v)  // Árabe
            || (0x0590...0x05FF).contains(v)  // Hebreo
            || (0x0E00...0x0E7F).contains(v)  // Tailandés
            || (0x0370...0x03FF).contains(v)  // Griego
            || (0x0900...0x097F).contains(v)  // Devanagari
    }
}
