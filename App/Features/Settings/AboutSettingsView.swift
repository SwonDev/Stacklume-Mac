import SwiftUI
import StacklumeDesignSystem

/// Panel «Acerca de»: nombre, versión (leída del `Bundle`), créditos y enlaces.
/// Paridad con la sección «Acerca de» del iPhone, adaptada a macOS.
struct AboutSettingsView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Image("StacklumeLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stacklume")
                            .stacklumeFont(.title3.weight(.bold))
                            .foregroundStyle(palette.textPrimary)
                        Text("Tu universo de enlaces, organizado.")
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                VStack(spacing: 0) {
                    infoRow("Versión", value: version)
                    Divider()
                    infoRow("Plataforma", value: "Mac · macOS 26")
                }
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                updatesSection

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Button {
                        openWindow(id: HelpView.windowID)
                    } label: {
                        Label("Ayuda y atajos de teclado", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .themedHelp("Abre la ventana de ayuda con todos los atajos de teclado")
                    Link(destination: URL(string: "https://stacklume.app")!) {
                        Label("Sitio web", systemImage: "globe")
                    }
                    .themedHelp("Abre stacklume.app en el navegador")
                    Link(destination: URL(string: "https://stacklume.app/privacy")!) {
                        Label("Privacidad", systemImage: "hand.raised")
                    }
                    .themedHelp("Lee la política de privacidad de Stacklume")
                }
                .tint(palette.accent)

                Text("Hecho con cariño en Canarias por SwonDev. © 2026 SwonDev.")
                    .stacklumeFont(.footnote)
                    .foregroundStyle(palette.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackground())

    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(palette.textPrimary).fontWeight(.medium)
        }
        .padding(DesignSystem.Spacing.sm)
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Actualizaciones", systemImage: "arrow.triangle.2.circlepath")
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)

            Toggle("Buscar actualizaciones automáticamente", isOn: automaticChecksBinding)
                .disabled(!StacklumeUpdater.shared.isStarted)
            Toggle("Descargar e instalar automáticamente", isOn: automaticDownloadsBinding)
                .disabled(!StacklumeUpdater.shared.isStarted)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Buscar ahora") {
                    StacklumeUpdater.shared.checkForUpdates()
                }
                .stacklumeButton(prominent: false, compact: true)
                .disabled(!StacklumeUpdater.shared.isStarted)

                Spacer()
                Link("Código fuente · MIT", destination: URL(string: "https://github.com/SwonDev/Stacklume-Mac")!)
            }
            .tint(palette.accent)

            Text("Las actualizaciones se verifican con firma EdDSA antes de instalarse.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            palette.surface,
            in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
        )
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { StacklumeUpdater.shared.automaticallyChecksForUpdates },
            set: { StacklumeUpdater.shared.automaticallyChecksForUpdates = $0 }
        )
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { StacklumeUpdater.shared.automaticallyDownloadsUpdates },
            set: { StacklumeUpdater.shared.automaticallyDownloadsUpdates = $0 }
        )
    }
}
