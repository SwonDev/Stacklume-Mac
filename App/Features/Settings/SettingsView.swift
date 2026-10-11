import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Escena de Ajustes nativa (⌘,). Pestañas: Apariencia, Privacidad, Datos,
/// Mantenimiento (enriquecer, comprobar, duplicados, papelera) y Acerca de.
///
/// La escena `Settings` es una ventana independiente que NO hereda el entorno de
/// la ventana principal, así que inyectamos aquí el tema activo (`stacklumeTheme`)
/// para que los swatches y los colores de marca se rendericen correctamente.
struct SettingsView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Query private var settings: [AppSettings]
    @AppStorage("stacklume.accentHex") private var accentHex = ""

    private var theme: Theme {
        Theme(rawValue: settings.first?.themeID ?? "dark") ?? .dark
    }

    /// Paleta del tema con el acento personalizado (igual que la ventana principal), para
    /// que la ventana independiente de Ajustes también muestre el acento elegido.
    private var palette: ThemePalette {
        var p = theme.palette(systemScheme: systemScheme)
        if !accentHex.isEmpty { p.accent = Color(hex: accentHex) }
        return p
    }

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Apariencia", systemImage: "paintbrush") }
            PrivacyAutomationSettingsView()
                .tabItem { Label("Privacidad", systemImage: "hand.raised.fill") }
            DataSettingsView()
                .tabItem { Label("Datos", systemImage: "externaldrive") }
            MaintenanceSettingsView()
                .tabItem { Label("Mantenimiento", systemImage: "wrench.and.screwdriver") }
            AboutSettingsView()
                .tabItem { Label("Acerca de", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 560)
        // Tematiza el titlebar de la VENTANA de Ajustes (antes gris del sistema): titlebar
        // transparente + fondo del tema. `fullSize: false` → el contenido NO sube bajo la barra de
        // pestañas (si no, se superponía con el contenido scrolleado por detrás).
        .background(WindowChrome(background: palette.background, fullSize: false))
        .environment(\.themePalette, palette)
        .environment(\.appTheme, theme)
        .tint(palette.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .tooltipLayer(palette)   // tooltips temáticos también en Ajustes
    }
}

/// Apariencia: selector de tema como grid visual de swatches agrupado
/// (Automático / Oscuros / Claros) + selector de idioma. Paridad con el iPhone.
private struct AppearanceSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @AppStorage(StacklumeTextScale.storageKey) private var textScalePercent = 100
    /// Atajo GLOBAL de guardado rápido (persistido; el `QuickSaveCoordinator` lo lee).
    @AppStorage(QuickSaveShortcut.storageKey) private var quickSaveShortcutRaw = QuickSaveShortcut.ctrlCmdS.rawValue
    /// Acento personalizado (hex). Vacío = el del tema.
    @AppStorage("stacklume.accentHex") private var accentHex = ""

    /// Color del acento actual (override o el del tema) para la rueda nativa.
    private var accentBinding: Binding<Color> {
        Binding(get: { palette.accent }, set: { accentHex = $0.hexString })
    }

    private var quickSaveBinding: Binding<QuickSaveShortcut> {
        Binding(
            get: { QuickSaveShortcut(rawValue: quickSaveShortcutRaw) ?? .ctrlCmdS },
            set: { quickSaveShortcutRaw = $0.rawValue
                   NotificationCenter.default.post(name: .stacklumeReloadHotKey, object: nil) })
    }

    /// Columnas adaptativas: caben varias por fila en la ventana de Ajustes.
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: DesignSystem.Spacing.sm)]

    private var currentThemeID: String { settingsList.first?.themeID ?? "dark" }

    private var lightThemes: [Theme] {
        Theme.allCases.filter { $0 != .system && $0.preferredColorScheme == .light }
    }
    private var darkThemes: [Theme] {
        Theme.allCases.filter { $0 != .system && $0.preferredColorScheme == .dark }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsList.first?.language ?? .es },
            set: { newValue in
                let current = AppSettingsStore.current(in: context)
                current.language = newValue
                current.updatedAt = Date()
                context.saveLogging()
            }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    themeSection(
                        title: "Automático", systemImage: "circle.lefthalf.filled",
                        themes: [.system],
                        footer: "Sigue la apariencia clara u oscura de tu Mac."
                    )
                    themeSection(
                        title: "Temas oscuros", systemImage: "moon.stars.fill",
                        themes: darkThemes, footer: nil
                    )
                    themeSection(
                        title: "Temas claros", systemImage: "sun.max.fill",
                        themes: lightThemes, footer: nil
                    )

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Color de acento", systemImage: "paintpalette.fill")
                            .stacklumeFont(.headline)
                            .foregroundStyle(palette.textPrimary)
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            ColorPicker("Color de acento", selection: accentBinding, supportsOpacity: false)
                                .labelsHidden()
                            Circle()
                                .fill(palette.accent)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(palette.border, lineWidth: 0.5))
                            Text(accentHex.isEmpty ? "Según el tema" : accentHex.uppercased())
                                .stacklumeFont(.callout.monospaced())
                                .foregroundStyle(palette.textSecondary)
                            Spacer()
                            if !accentHex.isEmpty {
                                Button("Restablecer") { withAnimation(reduceMotion ? nil : .snappy) { accentHex = "" } }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Text("Personaliza el dorado de Stacklume: foco, acción primaria, favoritos, estados activos y la barra de desplazamiento. Se aplica a toda la app al instante.")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Tamaño del texto", systemImage: "textformat.size")
                            .stacklumeFont(.headline)
                            .foregroundStyle(palette.textPrimary)
                        Picker("Tamaño del texto", selection: Binding(
                            get: { StacklumeTextScale(storedPercent: textScalePercent).rawValue },
                            set: { textScalePercent = StacklumeTextScale(storedPercent: $0).rawValue }
                        )) {
                            ForEach(StacklumeTextScale.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        Text("Amplía el texto hasta el doble. Se aplica a las ventanas y hojas de Stacklume.")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Idioma", systemImage: "globe")
                            .stacklumeFont(.headline)
                            .foregroundStyle(palette.textPrimary)
                        ViewThatFits(in: .horizontal) {
                            Picker("Idioma", selection: languageBinding) {
                                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Picker("Idioma", selection: languageBinding) {
                                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Text("Se aplica al instante en el contenido generado por la IA. El idioma de los menús del sistema sigue el de macOS; cierra y vuelve a abrir la app para verlo reflejado por completo.")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Guardado rápido", systemImage: "bolt.fill")
                            .stacklumeFont(.headline)
                            .foregroundStyle(palette.textPrimary)
                        ViewThatFits(in: .horizontal) {
                            Picker("Atajo global", selection: quickSaveBinding) {
                                ForEach(QuickSaveShortcut.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Picker("Atajo global", selection: quickSaveBinding) {
                                ForEach(QuickSaveShortcut.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Text("Atajo del sistema para guardar el enlace del portapapeles sin abrir la app. También tienes el icono de la barra de menús (arriba a la derecha) con el mismo guardado rápido.")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(width: max(0, geometry.size.width - 2 * DesignSystem.Spacing.lg), alignment: .leading)
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .background(WindowBackground())
    }

    private func themeSection(title: String, systemImage: String, themes: [Theme], footer: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label(title, systemImage: systemImage)
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                ForEach(themes) { theme in themeSwatch(theme) }
            }
            if let footer {
                Text(footer)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func themeSwatch(_ theme: Theme) -> some View {
        ThemeSwatch(theme: theme, systemScheme: systemScheme, isSelected: currentThemeID == theme.id) {
            withAnimation(reduceMotion ? nil : .snappy) {
                let current = AppSettingsStore.current(in: context)
                current.themeID = theme.id
                current.updatedAt = Date()
                context.saveLogging()
            }
        }
    }

}
