import SwiftUI
import SwiftData
import WebKit
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata
import StacklumePersistence

/// Lector de la copia offline (macOS): renderiza el HTML guardado en un WKWebView
/// (sin red, baseURL nil). Se presenta como hoja desde el detalle del enlace.
///
/// Si se pasa `bookmark`, al SELECCIONAR texto aparece un popover de colores y el
/// fragmento se guarda como `Highlight` (paridad con Raindrop); los resaltados ya
/// guardados se re-pintan al abrir.
struct OfflineReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    let title: String
    let html: String
    /// Enlace asociado: habilita crear/re-pintar resaltados desde la selección.
    var bookmark: Bookmark? = nil
    /// Tamaño de fuente del lector (compartido con el modo lectura del navegador).
    @AppStorage("stacklume.reader.fontPercent") private var readerFont = 100
    /// Lectura en voz alta (TTS on-device), observada para el estado del botón y la barra.
    @State private var aloud = ReadAloud.shared

    /// Texto legible del artículo para leer en voz alta: la copia offline si la hay, o el texto
    /// plano extraído del HTML que ya se muestra. Se limpia de CSS/ruido para no leerlo.
    private var articleText: String {
        let raw = (bookmark?.offlineText).flatMap { $0.count > 200 ? $0 : nil }
            ?? OfflineCopyService.plainText(from: html)
        return ProseText.clean(raw)
    }

    /// Idioma de la app (es/en) para elegir la voz del TTS.
    private var language: String { AppSettingsStore.current(in: context).language.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            // Barra superior con título y botón de cierre (estilo InAppBrowserSheet).
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
                .accessibilityLabel("Cerrar")

                Label("Copia sin conexión", systemImage: "book.closed.fill")
                    .stacklumeFont(.callout.weight(.medium))
                    .foregroundStyle(palette.accent)

                if bookmark != nil {
                    Label("Selecciona texto para resaltarlo", systemImage: "highlighter")
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .themedHelp("Selecciona cualquier fragmento y elige un color para guardarlo como resaltado")
                }

                Spacer()

                Button { readerFont = max(70, readerFont - 10) } label: { Image(systemName: "textformat.size.smaller") }
                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                    .disabled(readerFont <= 70).themedHelp("Reducir texto")
                    .accessibilityLabel("Reducir texto")
                Button { readerFont = min(180, readerFont + 10) } label: { Image(systemName: "textformat.size.larger") }
                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                    .disabled(readerFont >= 180).themedHelp("Agrandar texto")
                    .accessibilityLabel("Agrandar texto")

                // Leer en voz alta (TTS on-device): lee el artículo. Mientras suena, pausa/reanuda;
                // los controles completos (velocidad, salto de frase, detener) están en la barra inferior.
                let reading = aloud.isReading(bookmark?.id)
                Button {
                    if reading { aloud.togglePause() }
                    else { aloud.start(articleText, language: language, id: bookmark?.id) }
                } label: {
                    Image(systemName: reading ? (aloud.isPaused ? "play.circle.fill" : "pause.circle.fill") : "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .foregroundStyle(reading ? palette.accent : palette.textSecondary)
                .themedHelp(reading ? (aloud.isPaused ? "Reanudar" : "Pausar") : "Leer en voz alta")
                .accessibilityLabel(reading ? "Pausar lectura en voz alta" : "Leer en voz alta")

                Text(title.isEmpty ? "Sin título" : title)
                    .stacklumeFont(.callout.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(1)
            }
            .padding(10)
            .background(palette.surface)

            Divider()

            readerBody

            // Reproductor de voz: solo mientras se lee ESTE artículo. Reutiliza el componente
            // compartido (oración resaltada, progreso, velocidad, salto de frase, detener).
            if aloud.isReading(bookmark?.id) {
                Divider()
                ReadAloudBar(aloud: aloud)
                    .padding(10)
                    .background(palette.surface)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: 860, height: 660)
        .animation(.easeInOut(duration: 0.2), value: aloud.isReading(bookmark?.id))
        // Al cerrar el lector, detén la lectura de este artículo (no dejes audio huérfano).
        .onDisappear { if aloud.isReading(bookmark?.id) { aloud.stop() } }
    }

    /// Renderizador de HTML estático compartido con el navegador (modo lectura). Con
    /// `bookmark`, habilita resaltar desde la selección y re-pinta lo ya guardado.
    @ViewBuilder
    private var readerBody: some View {
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Estado vacío: la copia sin conexión aún no se ha guardado o está incompleta.
            ContentUnavailableView {
                Label("Contenido no disponible", systemImage: "wifi.slash")
            } description: {
                Text("La copia sin conexión de este artículo aún no se ha descargado. Abre el enlace con conexión para generarla.")
            }
        } else {
            StaticHTMLView(
                html: html,
                fontPercent: readerFont,
                highlights: (bookmark?.highlights ?? []).map { ReaderHighlight(text: $0.text, color: $0.colorHex) },
                highlightColors: bookmark == nil ? [] : ColorPresets.all,
                onHighlight: highlightHandler(),
                scrollKey: bookmark.map { CanonicalURL.key($0.url) }
            )
        }
    }

    /// Handler de resaltado con tipo EXPLÍCITO (evita un fallo de inferencia del compilador
    /// con el closure `@MainActor` opcional). `nil` si no hay enlace asociado.
    @MainActor
    private func highlightHandler() -> (@MainActor (String, String) -> Void)? {
        guard let bm = bookmark else { return nil }
        return { text, color in
            BookmarkActions.addHighlight(text: text, colorHex: color, to: bm, in: context)
        }
    }
}
