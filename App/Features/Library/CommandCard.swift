import SwiftUI
import AppKit
import StacklumeCore
import StacklumeMetadata
import StacklumeDesignSystem

/// Tarjeta de comando de instalación (npm i…, pip install…, brew install…) con el texto
/// en monoespaciado y un botón para copiarlo. Se muestra en el detalle y las filas cuando
/// `Bookmark.command` está presente. Porte del iPhone (NSPasteboard en vez de UIPasteboard,
/// sin feedback háptico). El color de la insignia lo da el gestor (CommandDetector).
struct CommandCard: View {
    @Environment(\.themePalette) private var palette
    let command: String
    var compact: Bool = false

    @State private var copied = false

    /// Gestor (primera palabra del comando) para la insignia de color.
    private var manager: String {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
    }
    private var managerColor: Color { Color(hex: CommandDetector.color(forManager: manager)) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "terminal.fill")
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(managerColor)
            Text(command)
                .stacklumeFont(.system(compact ? .caption2 : .footnote, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .stacklumeLineLimit(compact ? 1 : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.copyString(command)
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.snappy) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copied ? Color(hex: "#22C55E") : managerColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .themedHelp("Copiar comando")
            .accessibilityLabel(copied ? "Copiado" : "Copiar comando")
        }
        .padding(.horizontal, compact ? 8 : DesignSystem.Spacing.sm)
        .padding(.vertical, compact ? 5 : 8)
        .background(palette.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(managerColor.opacity(0.35), lineWidth: 1))
    }
}
