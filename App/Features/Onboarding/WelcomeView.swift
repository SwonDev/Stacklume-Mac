import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Pantalla de bienvenida (primer arranque). Presenta la app y, al pulsar
/// «Abrir mi biblioteca», marca el onboarding como completado.
struct WelcomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        Image("StacklumeLogo")
                            .resizable().scaledToFit().frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        Text("Bienvenido a Stacklume")
                            .stacklumeFont(.largeTitle.weight(.bold))
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Guarda, organiza y vuelve a encontrar tus enlaces.")
                            .stacklumeFont(.title3).foregroundStyle(palette.textSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        feature("books.vertical.fill", "Organiza tu biblioteca", "Colecciones, etiquetas, favoritos y cola de lectura.")
                        feature("doc.text.magnifyingglass", "Busca por significado", "Escribe en el buscador o abre ⌘K. Usa el botón junto al buscador para buscar con una imagen, PDF, audio o vídeo.")
                        feature("bubble.left.and.bubble.right", "Asistente con tus fuentes", "Conversa con tu biblioteca usando Liquid en este Mac. La búsqueda web es opcional.")
                        feature("at", "Conecta tu X", "Guarda publicaciones de X y sus enlaces en tu biblioteca.")
                        feature("paintpalette.fill", "24 temas y Liquid Glass", "Elige el tema y el acento en Ajustes › Apariencia.")
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Primera preparación")
                            .stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("EmbeddingGemma 2 prepara la búsqueda local automáticamente al abrir la biblioteca. La primera descarga requiere Internet; mientras tanto, puedes buscar por texto.")
                        Text("Consulta el progreso o reintenta desde Asistente IA › Ajustes de IA.")
                    }
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 500)
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity)
            }

            Button { complete() } label: {
                Text("Abrir mi biblioteca").stacklumeFont(.headline)
                    .frame(maxWidth: 280).padding(.vertical, DesignSystem.Spacing.xs)
            }
            .stacklumeButton()
            .keyboardShortcut(.defaultAction)
            .padding(DesignSystem.Spacing.md)
        }
        .frame(minWidth: 440, idealWidth: 600, maxWidth: 600,
               minHeight: 480, idealHeight: 640, maxHeight: 640)
        .background(WindowBackground())
    }

    private func feature(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon).font(.title2).foregroundStyle(palette.accent).frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                Text(desc).stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func complete() {
        let s = AppSettingsStore.current(in: context)
        s.onboardingCompleted = true
        context.saveLogging()
        onDone()
    }
}
