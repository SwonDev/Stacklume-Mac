import SwiftUI
import AVFoundation
import StacklumeDesignSystem

/// Barra-reproductor COMPARTIDA para la lectura en voz alta: muestra la ORACIÓN que suena con
/// la PALABRA en curso resaltada, una barra de progreso y los controles (frase anterior/siguiente,
/// pausa, velocidad y detener). La usan la ficha del enlace y el lector a pantalla completa,
/// observando el mismo `ReadAloud.shared` (un solo artículo suena a la vez). El que la muestra
/// decide CUÁNDO (p. ej. `if aloud.isReading(id) { ReadAloudBar(aloud: aloud) }`).
struct ReadAloudBar: View {
    let aloud: ReadAloud
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(highlightedSentence)
                .stacklumeFont(.callout)
                .stacklumeLineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.12), value: aloud.spokenIndex)
                .accessibilityLabel(aloud.sentenceText)

            ProgressView(value: aloud.progress)
                .tint(palette.accent)
                .accessibilityLabel("Progreso de lectura")
                .accessibilityValue("\(Int(aloud.progress * 100)) por ciento")

            HStack(spacing: DesignSystem.Spacing.md) {
                Button { aloud.skipSentence(forward: false) } label: {
                    Image(systemName: "backward.fill")
                }
                .themedHelp("Frase anterior")
                .accessibilityLabel("Frase anterior")

                Button { aloud.togglePause() } label: {
                    Image(systemName: aloud.isPaused ? "play.fill" : "pause.fill")
                }
                .themedHelp(aloud.isPaused ? "Reanudar" : "Pausar")
                .accessibilityLabel(aloud.isPaused ? "Reanudar" : "Pausar")

                Button { aloud.skipSentence(forward: true) } label: {
                    Image(systemName: "forward.fill")
                }
                .themedHelp("Frase siguiente")
                .accessibilityLabel("Frase siguiente")

                Spacer()

                voiceMenu

                speedMenu

                Button(role: .destructive) { aloud.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .themedHelp("Detener lectura")
                .accessibilityLabel("Detener lectura")
            }
            .stacklumeButton(prominent: false, compact: true)
            .scaledFont(14, weight: .semibold)
            .foregroundStyle(palette.textPrimary)
        }
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.textPrimary.opacity(0.08), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Menú de velocidad de lectura (0,5×–2×). Cambia `ReadAloud.speed` en vivo: la lectura se
    /// reanuda al instante desde la palabra actual con el nuevo ritmo.
    private var speedMenu: some View {
        Menu {
            ForEach(ReadAloud.speeds, id: \.self) { value in
                Button { aloud.speed = value } label: {
                    if aloud.speed == value {
                        Label(speedLabel(value), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(value))
                    }
                }
            }
        } label: {
            Text(speedLabel(aloud.speed))
                .stacklumeFont(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 38)
        }
        .menuStyle(.button)
        .stacklumeButton(prominent: false, compact: true)
        .themedHelp("Velocidad de lectura")
        .accessibilityLabel("Velocidad de lectura, \(speedLabel(aloud.speed))")
    }

    /// Menú de VOZ: «Automática (mejor)» + las voces instaladas (ordenadas por calidad) +
    /// «Descargar más voces…». La elegida se aplica en vivo. Autodetectable: la mejor por defecto.
    private var voiceMenu: some View {
        Menu {
            Button { aloud.setVoice(nil) } label: {
                Label("Voz automática (la mejor)",
                      systemImage: aloud.isVoiceAuto ? "checkmark" : "wand.and.stars")
            }
            let voices = ReadAloud.availableVoices(for: aloud.spokenLanguage)
            if !voices.isEmpty {
                Divider()
                ForEach(voices, id: \.identifier) { voice in
                    Button { aloud.setVoice(voice.identifier) } label: {
                        if !aloud.isVoiceAuto, voice.identifier == aloud.currentVoiceID {
                            Label(voiceLabel(voice), systemImage: "checkmark")
                        } else {
                            Text(voiceLabel(voice))
                        }
                    }
                }
            }
            Divider()
            Button { openSpokenContentSettings() } label: {
                Label("Activar voz Premium de España (Apple)…", systemImage: "sparkles")
            }
        } label: {
            Image(systemName: "person.wave.2.fill")
        }
        .menuStyle(.button)
        .stacklumeButton(prominent: false, compact: true)
        .themedHelp("Voz de lectura")
        .accessibilityLabel("Voz de lectura")
    }


    /// Nombre de la voz + su calidad: «Mónica (Premium)», «Paulina (Mejorada)».
    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:  "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Mejorada)"
        default:        voice.name
        }
    }

    /// Abre Ajustes del Sistema en Accesibilidad (donde se gestionan las voces de Contenido hablado).
    private func openSpokenContentSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") {
            openURL(url)
        }
    }

    /// Etiqueta de velocidad en español: «1×», «1,5×», «0,5×».
    private func speedLabel(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        return String(format: "%g×", value).replacingOccurrences(of: ".", with: ",")
    }

    /// La oración que suena con la PALABRA en curso resaltada (acento + énfasis); el resto
    /// atenuado. Convierte el rango UTF-16 del motor (`wordRangeInSentence`) a `AttributedString`.
    private var highlightedSentence: AttributedString {
        let sentence = aloud.sentenceText
        var attributed = AttributedString(sentence)
        attributed.foregroundColor = palette.textSecondary
        guard !sentence.isEmpty, let word = aloud.wordRangeInSentence else { return attributed }
        let utf16 = sentence.utf16
        guard let lo16 = utf16.index(utf16.startIndex, offsetBy: word.lowerBound, limitedBy: utf16.endIndex),
              let hi16 = utf16.index(utf16.startIndex, offsetBy: word.upperBound, limitedBy: utf16.endIndex),
              let lo = lo16.samePosition(in: sentence),
              let hi = hi16.samePosition(in: sentence), lo < hi,
              let range = Range(lo..<hi, in: attributed) else { return attributed }
        attributed[range].foregroundColor = palette.readableAccent(on: palette.surface)
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        return attributed
    }
}
