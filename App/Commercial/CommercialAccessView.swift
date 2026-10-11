import SwiftUI
import StacklumeDesignSystem

/// Puerta exclusiva de la build comercial. No altera ni migra el store SwiftData: al
/// activar la licencia aparece la misma `RootWindowView` y todos los datos siguen intactos.
struct CommercialAccessView: View {
    @State private var licenseManager = CommercialLicenseManager.shared

    var body: some View {
        Group {
            if licenseManager.hasAccess {
                RootWindowView()
            } else {
                CommercialLicenseActivationView(licenseManager: licenseManager)
            }
        }
        .task { licenseManager.start() }
    }
}

private struct CommercialLicenseActivationView: View {
    @Bindable var licenseManager: CommercialLicenseManager
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette {
        Theme.dark.palette(systemScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer(minLength: DesignSystem.Spacing.lg)

            Image("StacklumeLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Activa Stacklume para Mac")
                    .stacklumeFont(.title2.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                Text("Introduce la clave que recibiste al comprar la app. La activación no toca tu biblioteca ni sube tus enlaces.")
                    .stacklumeFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Clave de licencia")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)

                SecureField("STACKLUME_…", text: $licenseManager.licenseKeyInput)
                    .textContentType(.password)
                    .stacklumeFont(.body.monospaced())
                    .padding(DesignSystem.Spacing.sm)
                    .background(
                        palette.surface,
                        in: RoundedRectangle(
                            cornerRadius: DesignSystem.cornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: DesignSystem.cornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(palette.border.opacity(0.7), lineWidth: 0.5)
                    }
                    .onSubmit { licenseManager.activate() }

                if let message = licenseManager.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.accent)
                        .accessibilityLabel("Error: \(message)")
                } else if let message = licenseManager.statusMessage {
                    Label(message, systemImage: "checkmark.shield.fill")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                }

                Button {
                    licenseManager.activate()
                } label: {
                    if licenseManager.isWorking {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Comprobando…")
                        }
                    } else {
                        Label("Activar este Mac", systemImage: "checkmark.seal.fill")
                    }
                }
                .stacklumeButton()
                .controlSize(.large)
                .disabled(
                    licenseManager.isWorking
                        || !CommercialLicenseInput.isPlausibleKey(licenseManager.licenseKeyInput)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(width: 510)
            .background(
                palette.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.55), lineWidth: 0.5)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Link("Ayuda con mi licencia", destination: URL(string: "https://stacklume.app/faq")!)
            }
            .stacklumeFont(.callout)
            .tint(palette.accent)

            Text("La clave se guarda cifrada en el Llavero de macOS. Stacklume valida únicamente la licencia y protege las descargas de actualizaciones.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 510)

            Spacer(minLength: DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
        .environment(\.themePalette, palette)
        .environment(\.appTheme, Theme.dark)
        .tint(palette.accent)
        .preferredColorScheme(.dark)
    }
}
