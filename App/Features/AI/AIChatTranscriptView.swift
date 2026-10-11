import SwiftUI
import AppKit
import OSLog
import Foundation
import StacklumeDesignSystem

/// Datos de presentación: construir el DTO Message no instancia la conversación ni el runner.
struct AIChatTranscriptPresentation {
    let messages: [LiquidConversation.Message]
    let activeID: UUID
    let isResponding: Bool
    let researchProgress: String?
}

/// Único renderer del transcript: producción y ensayo RAM comparten disposición, filas y scroll.
struct AIChatTranscriptView: View {
    let chat: AIChatTranscriptPresentation
    @Binding var addedURLs: Set<String>
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.stacklumeFontMeasurement) private var fontMeasurement
    @Environment(\.fontResolutionContext) private var fontContext
    @Binding var expandedReferenceIDs: Set<String>
    @Binding var expandedDeckMessageIDs: Set<UUID>
    @Binding var chatViewportWidth: CGFloat
    @Binding var measuredChatContainerWidth: CGFloat
    @Binding var transcriptScroll: TranscriptScrollState
    let callbacks: AIChatTranscriptCallbacks
    let progressFallback: () -> String
    @State private var nativeTooltip: AIChatNativeTooltip?

    var body: some View {
        GeometryReader { geometry in
            let fonts = AIChatNativeFonts.resolve(context: fontContext, factor: textScale, measurement: fontMeasurement)
            let messages = chat.messages.map {
                AIChatNativeMessage(id: $0.id, isUser: $0.isUser, text: $0.text,
                    actions: $0.actions.map { .init(title: $0.title, systemImage: $0.systemImage) }, references: $0.references)
            }
            let rows = AIChatNativeRow.make(messages: messages, isResponding: chat.isResponding, progress: chat.researchProgress,
                expandedReferences: expandedReferenceIDs, expandedDecks: expandedDeckMessageIDs,
                addedURLs: addedURLs, fallback: chat.isResponding && chat.researchProgress == nil ? progressFallback() : "")
            AIChatNativeTranscriptRepresentable(input: .init(sessionID: chat.activeID, messages: messages, rows: rows,
                style: .init(fonts: fonts, palette: palette), addedURLs: addedURLs, expandedDecks: expandedDeckMessageIDs,
                containerWidth: geometry.size.width), scrollState: transcriptScroll, callbacks: callbacks,
                onWidthChange: { width, containerWidth in
                    if ScrollDiagnostics.recordsChatEvents {
                        ScrollDiagnostics.chatViewportCallback(width: Double(width), previousWidth: Double(chatViewportWidth),
                            containerWidth: Double(containerWidth), previousContainerWidth: Double(measuredChatContainerWidth),
                            state: .init(followsResponse: transcriptScroll.followsResponse, exploring: transcriptScroll.isExploring,
                                nearBottom: transcriptScroll.isNearBottom, messageCount: chat.messages.count,
                                tokenBlock: (chat.messages.last?.text.count ?? 0) / 180))
                    }
                    if abs(chatViewportWidth - width) >= 0.5 { chatViewportWidth = width }
                    measuredChatContainerWidth = containerWidth
                }, onToggleReference: { id in
                    transcriptScroll.followsResponse = false
                    let update = {
                        if expandedReferenceIDs.contains(id) { expandedReferenceIDs.remove(id) }
                        else { expandedReferenceIDs.insert(id) }
                    }
                    if reduceMotion { update() } else { withAnimation(.snappy(duration: 0.22)) { update() } }
                }, onToggleDeck: { id in
                    transcriptScroll.followsResponse = false
                    if expandedDeckMessageIDs.contains(id) { expandedDeckMessageIDs.remove(id) }
                    else { expandedDeckMessageIDs.insert(id) }
                }, onTooltipChange: { nativeTooltip = $0 })
                .overlay(alignment: .topLeading) {
                    if let nativeTooltip {
                        Color.clear
                            .frame(width: nativeTooltip.rect.width, height: nativeTooltip.rect.height)
                            .position(x: nativeTooltip.rect.midX, y: nativeTooltip.rect.midY)
                            .anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) {
                                TooltipRequest(text: nativeTooltip.text, anchor: $0)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}

/// Presentación segura del subconjunto estructural que produce el modelo. No usa el
/// intérprete Markdown del sistema, por lo que ningún texto generado crea enlaces o
/// acciones ejecutables de forma accidental.
struct AssistantStructuredResponseView: View {
    let text: String

    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.stacklumeFontMeasurement) private var fontMeasurement
    @Environment(\.fontResolutionContext) private var fontContext

    // Un solo layout de texto evita la negociación combinatoria entre filas de
    // viñetas, stacks y alineaciones de baseline durante el streaming de respuestas.
    // Los atributos se construyen sin interpretar Markdown ni añadir enlaces.
    private var formattedText: AttributedString {
        var result = AttributedString()
        for block in AssistantResponsePresentation.blocks(from: text) {
            if !result.characters.isEmpty { result.append(AttributedString("\n\n")) }
            let content: String
            switch block.kind {
            case .bullets:
                content = block.items.map { "• \($0)" }.joined(separator: "\n")
            case .numbered:
                content = block.items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            default:
                content = block.text
            }
            var part = AttributedString(content)
            part.foregroundColor = block.kind == .quote ? palette.textSecondary : palette.textPrimary
            switch block.kind {
            case .lead: part.font = scaledAttributedFont(.callout.weight(.medium))
            case .heading: part.font = scaledAttributedFont(.callout.weight(.semibold))
            case .quote: part.font = scaledAttributedFont(.body.italic())
            default: part.font = scaledAttributedFont(.body)
            }
            result.append(part)
        }
        return result
    }

    private func scaledAttributedFont(_ base: Font, line: Int = #line) -> Font {
        let factor = StacklumeTextScale.normalizedFactor(textScale)
        let font = factor == 1 ? base : base.scaled(by: factor)
        if let fontMeasurement {
            let original = base.resolve(in: fontContext)
            let actual = font.resolve(in: fontContext)
            fontMeasurement.record(#fileID, line, factor, original.pointSize, actual.pointSize, actual.isBold)
        }
        return font
    }

    var body: some View {
        Text(formattedText)
            .multilineTextAlignment(.leading)
    }
}
