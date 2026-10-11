import Foundation
import AVFoundation

/// Lectura en voz alta (TTS) de un artículo con `AVSpeechSynthesizer` del sistema — on-device,
/// sin red ni servicios externos. Equivale al «read aloud» de Pocket/GoodLinks/Readwise, pero
/// con **velocidad ajustable en vivo, salto por frases, barra de progreso y seguimiento de la
/// oración/palabra que suena** (para resaltarla). Es un singleton `@MainActor` para que solo
/// suene un artículo a la vez y la UI observe su estado.
@MainActor
@Observable
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    private let synth = AVSpeechSynthesizer()
    /// ¿Hay lectura en curso (sonando o en pausa)?
    private(set) var isActive = false
    private(set) var isPaused = false
    /// Enlace que se está leyendo (para resaltar su botón en la UI).
    private(set) var currentID: UUID?

    /// Multiplicadores de velocidad ofrecidos (sobre la velocidad natural del sistema).
    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let speedKey = "stacklume.tts.speed"

    /// Velocidad elegida por el usuario (multiplicador, p. ej. `1.5` = 1,5×). Persistida.
    /// Al cambiarla mientras se lee, se reanuda al instante desde la palabra actual con la
    /// nueva velocidad (AVSpeech no permite cambiar el ritmo de una locución ya en marcha).
    var speed: Float {
        didSet {
            guard speed != oldValue else { return }
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            applyLiveSpeed()
        }
    }

    // MARK: - Seguimiento de progreso (para resaltar y barra)

    /// Texto completo en lectura y su idioma, para reanudar desde un punto al cambiar de
    /// velocidad o saltar de frase.
    private var fullText: NSString = ""
    private(set) var spokenLanguage = "es"
    /// Desplazamiento (UTF-16) en `fullText` donde empieza la locución actual; sirve para
    /// mapear el rango que entrega el sistema (relativo a la locución) a `fullText`.
    private var baseOffset = 0
    /// Locución vigente: en `didFinish`/`didCancel` solo se limpia el estado si coincide,
    /// así un reinicio por velocidad/salto (que cancela la anterior) no apaga la lectura.
    private weak var currentUtterance: AVSpeechUtterance?

    /// Posición (UTF-16) por la que va la lectura dentro de `fullText`.
    private(set) var spokenIndex = 0
    /// Oración que suena ahora (recortada), para mostrarla y resaltar la palabra en curso.
    private(set) var sentenceText = ""
    /// Rango (UTF-16) de la palabra que suena DENTRO de `sentenceText`, para resaltarla.
    private(set) var wordRangeInSentence: Range<Int>?

    /// Progreso 0…1 de la lectura (por caracteres).
    var progress: Double {
        fullText.length > 0 ? min(1, Double(spokenIndex) / Double(fullText.length)) : 0
    }

    override private init() {
        let stored = UserDefaults.standard.object(forKey: Self.speedKey) as? Float
        self.speed = stored.map { min(2.0, max(0.5, $0)) } ?? 1.0
        super.init()
        synth.delegate = self
    }

    // MARK: - Control

    /// Empieza a leer el texto en el idioma indicado (es/en). Reinicia si ya había algo.
    func start(_ text: String, language: String, id: UUID?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        fullText = String(clean.prefix(50_000)) as NSString
        spokenLanguage = language
        currentID = id
        isActive = true
        isPaused = false
        speak(from: 0)
    }

    /// Pausa o reanuda la lectura.
    func togglePause() {
        guard isActive else { return }
        if isPaused {
            synth.continueSpeaking(); isPaused = false
        } else {
            synth.pauseSpeaking(at: .word); isPaused = true
        }
    }

    /// Salta a la frase siguiente o anterior y reanuda desde ahí (con la velocidad actual).
    func skipSentence(forward: Bool) {
        guard isActive else { return }
        let target = forward ? nextSentenceStart(after: spokenIndex)
                             : previousSentenceStart(before: spokenIndex)
        isPaused = false
        speak(from: target)
    }

    /// Detiene y limpia el estado.
    func stop() {
        currentUtterance = nil
        synth.stopSpeaking(at: .immediate)
        resetState()
    }

    /// ¿Está leyendo este enlace ahora mismo?
    func isReading(_ id: UUID?) -> Bool { isActive && currentID == id }

    // MARK: - Interno

    /// Velocidad real de `AVSpeechUtterance` para el multiplicador actual, acotada al rango
    /// admitido por el sistema.
    private var utteranceRate: Float {
        let raw = AVSpeechUtteranceDefaultSpeechRate * speed
        return min(AVSpeechUtteranceMaximumSpeechRate,
                   max(AVSpeechUtteranceMinimumSpeechRate, raw))
    }

    /// Reanuda desde la posición actual con la nueva velocidad (si está sonando, no en pausa).
    private func applyLiveSpeed() {
        guard isActive, !isPaused else { return }
        speak(from: spokenIndex)
    }

    /// Habla `fullText` desde un desplazamiento UTF-16. Cancela la locución previa SIN apagar
    /// el estado (gracias a `currentUtterance`), de modo que cambiar de velocidad o saltar de
    /// frase sea continuo.
    private func speak(from utf16Offset: Int) {
        let offset = max(0, min(utf16Offset, fullText.length))
        guard offset < fullText.length else { stop(); return }
        baseOffset = offset
        spokenIndex = offset
        let substring = fullText.substring(from: offset)
        let utterance = AVSpeechUtterance(string: substring)
        // Mejor voz disponible (premium/neural > mejorada > compacta), autodetectada o la que el
        // usuario haya elegido. Sin esto sonaba la voz «compacta» robótica por defecto.
        utterance.voice = Self.bestVoice(for: spokenLanguage)
        utterance.rate = utteranceRate
        utterance.postUtteranceDelay = 0
        currentUtterance = utterance         // marca la vigente ANTES de cancelar la anterior
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
    }

    private func resetState() {
        isActive = false; isPaused = false; currentID = nil
        spokenIndex = 0; sentenceText = ""; wordRangeInSentence = nil
        fullText = ""
    }

    // MARK: - Selección de voz (autodetectable: la MEJOR instalada)

    private static let voiceKeyPrefix = "stacklume.tts.voice."
    /// Cambia al elegir voz, para que el menú (que lee `currentVoiceID`) se refresque.
    private(set) var voiceTick = 0

    /// Calidad ordenable: premium (neural/Siri) > mejorada > compacta.
    private static func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q { case .premium: 3; case .enhanced: 2; default: 1 }
    }

    /// Prefijo de idioma y región «principal». Para español se exige **es-ES (España)**: así la
    /// voz es castellano PENINSULAR (Mónica/Jorge…), nunca latinoamericano (es-MX, Paulina).
    private static func langInfo(_ language: String) -> (prefix: String, main: String) {
        language == "en" ? ("en", "en-US") : ("es-ES", "es-ES")
    }

    /// Voces instaladas para un idioma, ordenadas de MEJOR a peor calidad (para el menú).
    static func availableVoices(for language: String) -> [AVSpeechSynthesisVoice] {
        let info = langInfo(language)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(info.prefix) }
            .sorted { a, b in
                if rank(a.quality) != rank(b.quality) { return rank(a.quality) > rank(b.quality) }
                if (a.language == info.main) != (b.language == info.main) { return a.language == info.main }
                return a.name < b.name
            }
    }

    /// Voz que SE USARÁ para un idioma: la elegida por el usuario si sigue instalada, o la de
    /// MAYOR calidad disponible (autodetectada). Cae a la del sistema si no hubiera ninguna.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKeyPrefix + language),
           let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        let voices = availableVoices(for: language)
        // Si hay alguna voz MEJORADA o PREMIUM (neural), se usa la mejor de esas.
        if let best = voices.first, best.quality != .default { return best }
        // Solo hay voces COMPACTAS: usar la voz ESTÁNDAR del sistema (Mónica/Samantha…), NO una
        // «novelty» (Eddy, Grandma, Rocko…), que saldría por orden alfabético y suena peor.
        return AVSpeechSynthesisVoice(language: langInfo(language).main) ?? voices.first
    }

    /// Identificador de la voz vigente para el idioma en lectura (para marcarla en el menú).
    var currentVoiceID: String? { Self.bestVoice(for: spokenLanguage)?.identifier }

    /// `true` si la voz es AUTOMÁTICA (no hay elegida a mano) → se usa la mejor instalada.
    var isVoiceAuto: Bool {
        _ = voiceTick   // dependencia observable para refrescar el menú tras elegir
        return UserDefaults.standard.string(forKey: Self.voiceKeyPrefix + spokenLanguage) == nil
    }

    /// `true` si la MEJOR voz disponible para el idioma es la BÁSICA (compacta/robótica): no hay
    /// ninguna mejorada/Premium instalada. La UI lo usa para ofrecer descargar una voz natural.
    var usingBasicVoice: Bool {
        _ = voiceTick
        guard let v = Self.bestVoice(for: spokenLanguage) else { return true }
        return v.quality == .default
    }

    /// Elige la voz (o `nil` = automática/mejor). Persiste por idioma y, si está leyendo, la
    /// aplica EN VIVO reanudando desde la palabra actual (AVSpeech no cambia la voz en marcha).
    func setVoice(_ identifier: String?) {
        let key = Self.voiceKeyPrefix + spokenLanguage
        if let identifier { UserDefaults.standard.set(identifier, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        voiceTick &+= 1
        if isActive, !isPaused { speak(from: spokenIndex) }
    }

    /// Actualiza la oración/palabra resaltada a partir del rango que el sistema va a hablar
    /// (relativo a la locución → se mapea a `fullText` con `baseOffset`).
    private func updateSpoken(_ relativeRange: NSRange) {
        let absLocation = baseOffset + relativeRange.location
        guard absLocation <= fullText.length else { return }
        spokenIndex = absLocation
        let sentence = sentenceRange(around: absLocation)
        sentenceText = fullText.substring(with: sentence)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Desplazamiento de la palabra dentro de la oración recortada (se descuenta lo que
        // recortó `trimmingCharacters` al inicio).
        let leadingTrim = leadingWhitespace(in: sentence)
        let wordStart = absLocation - sentence.location - leadingTrim
        let wordLen = max(0, min(relativeRange.length, sentenceText.utf16.count - wordStart))
        wordRangeInSentence = (wordStart >= 0 && wordLen > 0)
            ? wordStart..<(wordStart + wordLen) : nil
    }

    /// Cuenta los espacios/blancos iniciales de un rango de `fullText` (para alinear el
    /// resaltado con la oración ya recortada).
    private func leadingWhitespace(in range: NSRange) -> Int {
        var count = 0
        while count < range.length,
              let scalar = Unicode.Scalar(fullText.character(at: range.location + count)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            count += 1
        }
        return count
    }

    private static let terminators = CharacterSet(charactersIn: ".!?…。！？\n")

    /// Rango (UTF-16) de la oración que contiene la posición dada, delimitada por signos de
    /// fin de frase o salto de línea.
    private func sentenceRange(around loc: Int) -> NSRange {
        let n = fullText.length
        guard n > 0 else { return NSRange(location: 0, length: 0) }
        let p = min(max(0, loc), n - 1)
        var start = p
        while start > 0, !isTerminator(at: start - 1) { start -= 1 }
        var end = p
        while end < n, !isTerminator(at: end) { end += 1 }
        if end < n { end += 1 }   // incluye el propio signo de cierre
        return NSRange(location: start, length: end - start)
    }

    private func nextSentenceStart(after loc: Int) -> Int {
        let n = fullText.length
        var i = min(loc, n)
        while i < n, !isTerminator(at: i) { i += 1 }
        while i < n, isTerminatorOrSpace(at: i) { i += 1 }
        return i
    }

    private func previousSentenceStart(before loc: Int) -> Int {
        // Inicio de la oración ACTUAL; si ya estamos casi al principio, va a la anterior.
        let current = sentenceRange(around: max(0, loc - 1)).location
        if loc - current > 2 { return current }
        var i = max(0, current - 1)
        while i > 0, isTerminatorOrSpace(at: i - 1) { i -= 1 }
        return sentenceRange(around: max(0, i - 1)).location
    }

    private func isTerminator(at i: Int) -> Bool {
        guard let s = Unicode.Scalar(fullText.character(at: i)) else { return false }
        return Self.terminators.contains(s)
    }

    private func isTerminatorOrSpace(at i: Int) -> Bool {
        guard let s = Unicode.Scalar(fullText.character(at: i)) else { return false }
        return Self.terminators.contains(s) || CharacterSet.whitespaces.contains(s)
    }

    // MARK: - AVSpeechSynthesizerDelegate (en hilo arbitrario → saltamos al MainActor)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // Capturamos la identidad (Sendable) antes de cruzar el aislamiento de actor
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.currentUtterance,
                  ObjectIdentifier(current) == id else { return }
            self.updateSpoken(characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.currentUtterance,
                  ObjectIdentifier(current) == id else { return }  // ignora cancelaciones por reinicio
            self.resetState()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.currentUtterance,
                  ObjectIdentifier(current) == id else { return }
            self.resetState()
        }
    }
}
