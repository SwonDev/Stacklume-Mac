import SwiftUI
import StacklumeDesignSystem

struct ModelCatalogFormSection<Content: View>: View {
    private let title: String?
    private let content: Content
    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if let title {
                Text(title).stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSystem.Spacing.md)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(palette.textPrimary)
        .tint(palette.accent)
    }
}

struct ModelCatalogField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    var showsLabel = true
    var externalFocus: FocusState<Bool>.Binding? = nil
    @FocusState private var localFocus: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, text: Binding<String>, prompt: String = "", secure: Bool = false,
         showsLabel: Bool = true, externalFocus: FocusState<Bool>.Binding? = nil) {
        self.title = title; _text = text; self.prompt = prompt; self.secure = secure
        self.showsLabel = showsLabel; self.externalFocus = externalFocus
    }

    private var focus: FocusState<Bool>.Binding { externalFocus ?? $localFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if showsLabel { Text(title).stacklumeFont(.caption).foregroundStyle(palette.textSecondary) }
            Group {
                if secure {
                    SecureField(title, text: $text, prompt: Text(prompt).foregroundStyle(palette.textSecondary))
                        .textContentType(.password)
                } else {
                    TextField(title, text: $text, prompt: Text(prompt).foregroundStyle(palette.textSecondary))
                }
            }
            .textFieldStyle(.plain)
            .stacklumeDefaultFont(factor: textScale)
            .focused(focus)
            .focusEffectDisabled()
            .foregroundStyle(palette.textPrimary)
            .tint(palette.accent)
            .padding(DesignSystem.Spacing.sm)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isEnabled && focus.wrappedValue ? (palette.readableForeground(palette.accent,
                                                                                              on: [palette.background, palette.surface],
                                                                                              minimumContrast: 3) ?? palette.textPrimary) : palette.border,
                                  lineWidth: isEnabled && focus.wrappedValue ? 2 : 1)
            }
            .accessibilityLabel(title)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}

struct ModelCatalogPicker<Selection: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: Selection
    private let content: Content
    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title; _selection = selection; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
                .stacklumeDefaultFont(factor: textScale)
                .labelsHidden()
                .buttonStyle(.plain)
                .menuIndicator(.visible)
                .foregroundStyle(palette.textPrimary)
                .tint(palette.accent)
                .focused($isFocused)
                .focusEffectDisabled()
                .padding(DesignSystem.Spacing.sm)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isEnabled && isFocused ? (palette.readableForeground(palette.accent,
                                                                                         on: [palette.background, palette.surface],
                                                                                         minimumContrast: 3) ?? palette.textPrimary) : palette.border,
                                      lineWidth: isEnabled && isFocused ? 2 : 1)
                }
                .accessibilityLabel(title)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}

enum ModelCatalogFilterOptions {
    static func sorts(for provider: ModelCatalogProvider) -> [(value: String, title: String)] {
        provider == .huggingFace ? [
            ("", "Tendencias"), ("downloads", "Descargas"), ("likes", "Me gusta"),
            ("lastModified", "Última actualización"), ("createdAt", "Creación")
        ] : [
            ("", "Más descargados"), ("Highest Rated", "Mejor valorados"), ("Newest", "Más recientes"),
            ("Most Liked", "Más favoritos"), ("Most Collected", "Más coleccionados"),
            ("Most Discussed", "Más comentados"), ("Most Images", "Más imágenes"),
            ("Oldest", "Más antiguos"), ("Recently Added", "Añadidos recientemente")
        ]
    }
}
