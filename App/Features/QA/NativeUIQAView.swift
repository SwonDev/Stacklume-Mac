import SwiftUI
import Observation
import AppKit
import SwiftData
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Controles de ensayo separados de las vistas reales; todo su estado pertenece a este contenedor RAM.
struct NativeUIQAView: View {
    let scope: NativeUIQAConfiguration.Scope
    @State private var container: ModelContainer
    @State private var generation = 0
    @State private var reportWritten = false

    init(scope: NativeUIQAConfiguration.Scope, container: ModelContainer) {
        self.scope = scope
        _container = State(initialValue: container)
    }

    var body: some View {
        NativeUIQASampleView(scope: scope, generation: generation, reportWritten: $reportWritten, onReset: reset)
            .modelContainer(container)
            .id(generation)
    }

    private func reset() {
        do {
            container = try NativeUIQAModel.makeContainer()
            generation += 1
        } catch { NativeUIQAConfiguration.stop(error) }
    }
}

private struct NativeUIQASampleView: View {
    let scope: NativeUIQAConfiguration.Scope
    let generation: Int
    @Binding var reportWritten: Bool
    let onReset: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemMotion
    @Environment(\.accessibilityReduceTransparency) private var systemTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.colorScheme) private var observedScheme
    @Query private var settings: [AppSettings]
    @State private var theme: Theme = .dark
    @State private var localAccentHex: String?
    @State private var systemScheme: ColorScheme = .dark
    @State private var textSize: DynamicTypeSize = .large
    @State private var textScalePercent = 100
    @State private var fontMeasurements = StacklumeFontMeasurements()
    @State private var policyChoice = PolicyChoice.system
    @State private var motion = false
    @State private var transparency = false
    @State private var contrast = false
    @State private var surface = Surface.welcome
    @State private var specimenSize = SpecimenSize.standard
    @State private var showWelcome = true
    @State private var showEditor = false
    @State private var favorite = false
    @State private var selected = false
    @State private var interactions = 0
    @State private var completionCount = 0
    @State private var localText = "Texto de ensayo en memoria"
    @State private var selectorColorHex = "#D4A853"
    @State private var selectorIcon = "folder.fill"
    @State private var selectorText = "Valor de ensayo"
    @State private var chatFixture = NativeUIQAChatState()
    @State private var chatProfile = NativeUIQAChatFixture.Profile.ascii

    private enum Surface: String, CaseIterable, Identifiable {
        case welcome = "Bienvenida", components = "Componentes", themes = "Temas", catalog = "Catálogo", chat = "Chat", selectors = "Selectores", transcript = "Historial largo"
        var id: String { rawValue }
    }
    private enum PolicyChoice: String, CaseIterable, Identifiable {
        case system = "Sistema observado", injected = "Política local QA"
        var id: String { rawValue }
    }
    private enum SpecimenSize: String, CaseIterable, Identifiable {
        case standard = "600 × 640", compact = "440 × 480", wide = "760 × 680"
        var id: String { rawValue }
        var width: CGFloat { switch self { case .standard: 600; case .compact: 440; case .wide: 760 } }
        var height: CGFloat { switch self { case .standard: 640; case .compact: 480; case .wide: 680 } }
    }
    private var palette: ThemePalette {
        var resolved = theme.palette(systemScheme: systemScheme)
        if let localAccentHex { resolved.accent = Color(hex: localAccentHex) }
        return resolved
    }
    private var accessibility: NativeUIQAAccessibility? {
        policyChoice == .system ? nil : .init(reduceMotion: motion, reduceTransparency: transparency,
                                              increasedContrast: contrast)
    }
    private var effectiveMotion: Bool { accessibility?.motion(system: systemMotion) ?? systemMotion }
    private var actualSystemScheme: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            controls.frame(width: 300)
            Divider().overlay(palette.border)
            specimen
                .frame(width: specimenSize.width, height: specimenSize.height, alignment: .top)
                .tooltipLayer(palette)
                .environment(\.nativeUIQAAccessibility, accessibility)
                .dynamicTypeSize(textSize)
                .stacklumeDefaultFont(factor: StacklumeTextScale(storedPercent: textScalePercent).factor)
                .environment(\.stacklumeTextScale, StacklumeTextScale(storedPercent: textScalePercent).factor)
                .environment(\.stacklumeFontMeasurement, StacklumeFontMeasurement(record: fontMeasurements.record))
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: max(960, specimenSize.width + 360), minHeight: 740)
        .background(WindowBackground())
        .background(WindowChrome(background: palette.background, fullSize: false))
        .environment(\.themePalette, palette)
        .environment(\.appTheme, theme)
        .environment(\.colorScheme, theme.preferredColorScheme ?? systemScheme)
        .tint(palette.accent)
        .preferredColorScheme(theme.preferredColorScheme ?? systemScheme)
        .onChange(of: surface) { _, current in
            if current != .transcript { chatFixture.invalidate() }
        }
        .onDisappear { chatFixture.invalidate() }
        .sheet(isPresented: $showEditor) {
            EditorScaffold(title: "Formulario de ensayo", confirmTitle: "Confirmar",
                           onCancel: { showEditor = false }, onConfirm: { interactions += 1; showEditor = false }) {
                Form { TextField("Texto local", text: $localText) }.brandedForm()
                    .padding(DesignSystem.Spacing.md)
            }
            .frame(width: 480)
            .themedSheet(palette, theme)
            .environment(\.nativeUIQAAccessibility, accessibility)
            .dynamicTypeSize(textSize)
                .stacklumeDefaultFont(factor: StacklumeTextScale(storedPercent: textScalePercent).factor)
                .environment(\.stacklumeTextScale, StacklumeTextScale(storedPercent: textScalePercent).factor)
                .environment(\.stacklumeFontMeasurement, StacklumeFontMeasurement(record: fontMeasurements.record))
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Ensayo nativo").stacklumeFont(.title2.bold()).foregroundStyle(palette.textPrimary)
                Text("Vistas reales con preferencias en memoria. Este ensayo no certifica la app completa.")
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Picker("Superficie", selection: Binding(get: { surface }, set: { fontMeasurements.clear(); surface = $0 })) {
                    ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
                }
                if surface == .transcript {
                    Picker("Perfil de historial RAM", selection: $chatProfile) {
                        ForEach(NativeUIQAChatFixture.Profile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Cargar historial completo en RAM") { chatFixture.load(chatProfile, streaming: false) }
                    Button("Preparar 399 completos y último parcial") { chatFixture.load(chatProfile, streaming: true) }
                        .disabled(chatProfile == .references)
                    Button(chatFixture.stream.isRunning ? "Streaming en curso" : "Iniciar o reanudar streaming local") {
                        chatFixture.startStreaming()
                    }
                    .disabled(!chatFixture.canStream || chatFixture.stream.isRunning || chatFixture.isLoading)
                    Button("Detener y drenar streaming") { chatFixture.stopStreaming() }
                    Button("Completar último mensaje en RAM") { chatFixture.completeStreaming() }
                        .disabled(!chatFixture.canStream || chatFixture.isLoading)
                    Button("Cambiar sesión RAM") { chatFixture.nextSession() }
                        .disabled(chatFixture.sessionCount < 2 || chatFixture.isLoading)
                    Text(chatFixture.status).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Tamaño de muestra", selection: $specimenSize) {
                    ForEach(SpecimenSize.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Tema local", selection: $theme) {
                    ForEach(Theme.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Acento de ensayo independiente").stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                HStack {
                    ForEach(["#000000", "#FFFFFF", "#5B5B5B"], id: \.self) { hex in
                        Button(hex == "#000000" ? "Negro" : (hex == "#FFFFFF" ? "Blanco" : "Gris")) {
                            localAccentHex = hex
                        }
                        .accessibilityValue(localAccentHex == hex ? "Seleccionado" : "Sin seleccionar")
                    }
                }
                Button("Restaurar acento del tema") { localAccentHex = nil }
                Picker("Esquema de Sistema", selection: $systemScheme) {
                    Text("Claro").tag(ColorScheme.light); Text("Oscuro").tag(ColorScheme.dark)
                }
                Text("Esquema de la app según macOS: \(actualSystemScheme == "dark" ? "oscuro" : "claro").")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                Picker("Escala real del texto local", selection: Binding(
                    get: { textScalePercent }, set: { fontMeasurements.clear(); textScalePercent = $0 }
                )) {
                    ForEach(StacklumeTextScale.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Escala explícita macOS; Dynamic Type se ensaya por separado.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                Picker("Tamaño de texto local", selection: Binding(get: { textSize }, set: { fontMeasurements.clear(); textSize = $0 })) {
                    Text("Estándar").tag(DynamicTypeSize.large)
                    Text("Muy grande").tag(DynamicTypeSize.xxxLarge)
                    Text("Accesibilidad 3").tag(DynamicTypeSize.accessibility3)
                    Text("Accesibilidad 5").tag(DynamicTypeSize.accessibility5)
                }
                Picker("Accesibilidad", selection: $policyChoice) {
                    ForEach(PolicyChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                if policyChoice == .injected {
                    Toggle("Reducir movimiento local", isOn: $motion)
                    Toggle("Reducir transparencia local", isOn: $transparency)
                    Toggle("Contraste aumentado local", isOn: $contrast)
                }
                Text("SO observado: movimiento \(systemMotion ? "reducido" : "normal"), transparencia \(systemTransparency ? "reducida" : "normal"), contraste \(systemContrast == .increased ? "aumentado" : "normal").")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Bienvenida completada en RAM: \(settings.first?.onboardingCompleted == true ? "sí" : "no"). Acciones: \(interactions). Cierres de bienvenida: \(completionCount).")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                Button("Nuevo primer inicio en memoria", action: onReset)
                Button("Guardar recibo de esta muestra", action: saveReport).disabled(reportWritten)
                Text("No se activan los servicios ni pipelines de la biblioteca.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
        }
    }

    @ViewBuilder private var specimen: some View {
        switch surface {
        case .welcome:
            if showWelcome {
                WelcomeView {
                    showWelcome = false; completionCount += 1
                }
            } else {
                Text("La acción real de WelcomeView ha completado la bienvenida en memoria.")
                    .stacklumeFont(.title3).foregroundStyle(palette.textPrimary)
            }
        case .themes:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: DesignSystem.Spacing.sm)]) {
                    ForEach(Theme.allCases) { candidate in
                        ThemeSwatch(theme: candidate, systemScheme: systemScheme, isSelected: theme == candidate) {
                            withAnimation(effectiveMotion ? nil : .snappy) { theme = candidate }
                            AppSettingsStore.current(in: context).themeID = candidate.id
                            context.saveLogging(); interactions += 1
                        }
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
        case .components:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                Text("Componentes canónicos").stacklumeFont(.title2).foregroundStyle(palette.textPrimary)
                Text("Texto que usa ScaledFont").scaledFont(17).foregroundStyle(palette.textPrimary)
                Button("Abrir formulario real") { showEditor = true }.stacklumeButton()
                Button("Acción secundaria") { interactions += 1 }.stacklumeButton(prominent: false)
                Button("Botón desactivado") {}.stacklumeButton().disabled(true)
                Button("Pulsación real") { interactions += 1 }.buttonStyle(.pressable)
                Button("Ayuda temática") { interactions += 1 }
                    .themedHelp("Esta ayuda es el tooltip real de Stacklume.")
                TextField("Campo local", text: $localText)
            }
            .foregroundStyle(palette.textPrimary)
            .padding(DesignSystem.Spacing.lg)
        case .catalog:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                ModelCatalogResultCard(item: Self.catalogItem, adultFilter: .exclude, size: .comfortable,
                    isSelected: selected, isFavorite: favorite, onOpen: { selected.toggle(); interactions += 1 },
                    onPreview: { _ in interactions += 1 }, onFavorite: { favorite.toggle(); interactions += 1 },
                    onSave: { showEditor = true })
                    .frame(width: 340)
                Text("Fixture del DTO real sin medios ni direcciones; solo se ensaya la tarjeta, no el catálogo completo.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
        case .selectors:
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text("Selectores reales").stacklumeFont(.title2).foregroundStyle(palette.textPrimary)
                    HStack {
                        ForEach(["#000000", "#FFFFFF", "#5B5B5B"], id: \.self) { hex in
                            Button(hex == "#000000" ? "Negro" : (hex == "#FFFFFF" ? "Blanco" : "Gris")) {
                                selectorColorHex = hex
                            }
                            .accessibilityValue(selectorColorHex == hex ? "Seleccionado" : "Sin seleccionar")
                        }
                    }
                    ColorSwatchPicker(selection: $selectorColorHex)
                    TagChip(name: "Etiqueta de ensayo", colorHex: selectorColorHex)
                    ModelCatalogField("Valor local del catálogo", text: $selectorText, prompt: "Escribe aquí")
                    IconPicker(selection: $selectorIcon, tint: Color(hex: selectorColorHex))
                    Text("Color: \(selectorColorHex). Icono: \(selectorIcon). Estado exclusivo de esta muestra en RAM.")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.md)
            }
        case .transcript:
            AIChatTranscriptView(chat: chatFixture.presentation,
                addedURLs: Binding(get: { chatFixture.addedURLs }, set: { chatFixture.addedURLs = $0 }),
                expandedReferenceIDs: Binding(get: { chatFixture.expandedReferenceIDs }, set: { chatFixture.expandedReferenceIDs = $0 }),
                expandedDeckMessageIDs: Binding(get: { chatFixture.expandedDeckMessageIDs }, set: { chatFixture.expandedDeckMessageIDs = $0 }),
                chatViewportWidth: Binding(get: { chatFixture.chatViewportWidth }, set: { chatFixture.chatViewportWidth = $0 }),
                measuredChatContainerWidth: Binding(get: { chatFixture.measuredChatContainerWidth }, set: { chatFixture.measuredChatContainerWidth = $0 }),
                transcriptScroll: Binding(get: { chatFixture.transcriptScroll }, set: { chatFixture.transcriptScroll = $0 }),
                callbacks: AIChatTranscriptCallbacks(
                    send: { _ in chatFixture.recordAction() }, copy: { _ in chatFixture.recordAction() },
                    regenerate: { chatFixture.recordAction() }, preview: { _ in chatFixture.recordAction() },
                    open: { _ in chatFixture.recordAction() },
                    add: { references in chatFixture.addedURLs.formUnion(references.map(\.url)); chatFixture.recordAction() }),
                progressFallback: { "Streaming sintético en memoria…" })
                .background(WindowBackground())
        case .chat:
            ScrollView {
              VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                ChatBubble(isUser: true, availableWidth: specimenSize.width) {
                    Text("Quiero organizar mis fuentes y leerlas con claridad.")
                }
                ChatBubble(isUser: false, availableWidth: specimenSize.width) {
                    AssistantStructuredResponseView(text: "Resumen de muestra\n\nPuedes agrupar tus fuentes por tema.\n\n- Organiza la biblioteca\n- Revisa tu cola de lectura\n\n> Este contenido permanece en memoria.")
                }
                ChatBubble(isUser: false, availableWidth: specimenSize.width) { Text("…") }
                Text("Burbujas y respuesta estructurada reales; no se instancia una conversación ni un modelo.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
              }
            }
        }
    }

    static var catalogItem: ModelCatalogItem {
        .init(id: "native-ui-qa", provider: .huggingFace, title: "Modelo de muestra local", author: "Autor de ensayo",
              kind: "Transformador", library: "Biblioteca de muestra", description: "Muestra en memoria",
              tags: [], licenses: [], downloads: 1200, likes: 42, lastModified: nil, isPrivate: false,
              gated: nil, isAdult: false,
              versions: [.init(id: "qa-v1", name: "Versión de muestra", revision: "qa-revision", baseModel: "Base local",
                               createdAt: nil, description: "", trainedWords: [], files: [], previews: [])],
              allowsNoCredit: nil, allowsDerivatives: nil, allowsDifferentLicenses: nil,
              commercialUses: [], availability: nil, contentRating: .pg)
    }

    private func saveReport() {
        do {
            try NativeUIQAConfiguration.writeReport(scope, phase: "result", values: [
                "chatFixture": chatFixture.report,
                "surface": surface.rawValue, "theme": theme.id, "textSize": String(describing: textSize),
                "memoryGeneration": generation,
                "textScalePercent": textScalePercent, "fontPointReadings": fontMeasurements.snapshot,
                "fontGeometryMeasured": false, "fontReadingsLimitReached": fontMeasurements.reachedLimit,
                "selectorColorHex": selectorColorHex, "selectorIcon": selectorIcon,
                "localAccentOverride": localAccentHex ?? "tema",
                "specimenSize": ["width": specimenSize.width, "height": specimenSize.height],
                "observedWindowScheme": observedScheme == .dark ? "dark" : "light",
                "actualSystemScheme": actualSystemScheme,
                "qaSystemScheme": systemScheme == .dark ? "dark" : "light",
                "effectiveThemeScheme": (theme.preferredColorScheme ?? systemScheme) == .dark ? "dark" : "light",
                "observedSystem": ["reduceMotion": systemMotion, "reduceTransparency": systemTransparency,
                                   "increasedContrast": systemContrast == .increased],
                "policyInjected": accessibility != nil,
                "effectivePolicy": ["reduceMotion": effectiveMotion,
                    "reduceTransparency": accessibility?.transparency(system: systemTransparency) ?? systemTransparency,
                    "increasedContrast": accessibility?.contrast(system: systemContrast) == .increased || (accessibility == nil && systemContrast == .increased)],
                "onboardingCompletedInMemory": settings.first?.onboardingCompleted == true,
                "interactions": interactions, "completionCount": completionCount,
                "catalogMediaCandidateCount": ModelCatalogCoverCandidates(item: Self.catalogItem, adultFilter: .exclude).urls.count
            ])
            reportWritten = true
        } catch { NativeUIQAConfiguration.stop(error) }
    }
}


/// Propietario efímero del DTO de la vista: no construye LiquidConversation ni consulta servicios.
@MainActor
@Observable
private final class NativeUIQAChatState {
    private(set) var fixture: NativeUIQAChatFixture?
    private(set) var messageSessions: [[LiquidConversation.Message]] = []
    private(set) var activeIndex = 0
    private(set) var isLoading = false
    private(set) var failure = false
    private(set) var localActions = 0
    var addedURLs: Set<String> = []
    var expandedReferenceIDs: Set<String> = []
    var expandedDeckMessageIDs: Set<UUID> = []
    var chatViewportWidth: CGFloat = 0
    var measuredChatContainerWidth: CGFloat = 0
    var transcriptScroll = TranscriptScrollState()
    let stream = NativeUIQAChatStream()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private let emptySessionID = UUID()
    @ObservationIgnored private var preparedForStreaming = false

    var messages: [LiquidConversation.Message] { messageSessions.indices.contains(activeIndex) ? messageSessions[activeIndex] : [] }
    var sessionCount: Int { messageSessions.count }
    var canStream: Bool {
        preparedForStreaming && !messages.isEmpty
            && (messages.last?.text.count ?? 0) < (fixture?.sessions[activeIndex].messages.last?.text.count ?? 0)
    }
    var presentation: AIChatTranscriptPresentation {
        .init(messages: messages, activeID: fixture?.sessions[activeIndex].id ?? emptySessionID,
              isResponding: stream.isRunning, researchProgress: nil)
    }
    var status: String {
        if isLoading { return "Preparando payload completo en RAM…" }
        if failure { return "El fixture completo no cumple los límites; no se ha recortado." }
        guard let fixture else { return "Carga un perfil para ensayar el transcript real." }
        return "Sesión \(activeIndex + 1) de \(sessionCount); \(messages.count) mensajes activos. JSON agregado completo: \(fixture.encodedBytes) bytes. Tareas de streaming: \(stream.inFlightTasks). Acciones RAM: \(localActions)."
    }
    var report: [String: Any] {
        let lengths = messages.map { $0.text.count }
        return ["loaded": fixture != nil, "profile": fixture?.profile.rawValue ?? "sin cargar",
            "activeSessionOrdinal": activeIndex, "logicalSessionCount": sessionCount, "renderedSessionCount": fixture == nil ? 0 : 1,
            "activeMessageCount": messages.count, "activeMinimumCharacters": lengths.min() ?? 0,
            "activeMaximumCharacters": lengths.max() ?? 0,
            "activeTextUTF8Bytes": messages.reduce(0) { $0 + $1.text.utf8.count },
            "completeAggregateJSONBytes": fixture?.encodedBytes ?? 0,
            "maximumAggregateJSONBytes": AssistantConversationStore.maximumFileBytes,
            "JSONHeadroomBytes": fixture.map { AssistantConversationStore.maximumFileBytes - $0.encodedBytes } ?? 0,
            "preparedForStreaming": preparedForStreaming, "streamRunning": stream.isRunning,
            "streamTasks": stream.inFlightTasks, "lastTokenBlock": (messages.last?.text.count ?? 0) / 180,
            "localActions": localActions, "storeCalls": 0, "modelCalls": 0, "externalCalls": 0]
    }

    func load(_ profile: NativeUIQAChatFixture.Profile, streaming: Bool) {
        invalidate()
        let token = generation
        isLoading = true
        failure = false
        controlTask = Task { [weak self] in
            guard let self else { return }
            await self.stream.stopAndDrain()
            guard !Task.isCancelled, self.generation == token else { return }
            do {
                let fixture = try NativeUIQAChatFixture.make(profile)
                let sessions = fixture.sessions.map { session in
                    session.messages.map { stored in
                        LiquidConversation.Message(isUser: stored.isUser, text: stored.text, references: stored.references)
                    }
                }
                guard !Task.isCancelled, self.generation == token else { return }
                self.fixture = fixture
                self.messageSessions = sessions
                self.activeIndex = 0
                self.addedURLs = []
                self.localActions = 0
                self.preparedForStreaming = streaming && profile != .references
                if self.preparedForStreaming, let last = self.messageSessions[0].indices.last {
                    self.messageSessions[0][last].text = String(self.messageSessions[0][last].text.prefix(180))
                }
                if profile == .references, let last = self.messageSessions[0].indices.last {
                    self.messageSessions[0][last].actions = [.init(title: "Fuentes de ensayo RAM", systemImage: "books.vertical")]
                }
            } catch { self.failure = true }
            self.isLoading = false
            self.controlTask = nil
        }
    }

    func startStreaming() {
        guard canStream, !isLoading, let fixture, let last = messages.last,
              let complete = fixture.sessions[activeIndex].messages.last?.text else { return }
        let token = generation
        let session = activeIndex
        stream.begin(from: last.text, to: complete) { [weak self] text in
            guard let self, self.generation == token, self.activeIndex == session,
                  self.messageSessions[session].last?.id == last.id,
                  let index = self.messageSessions[session].indices.last else { return }
            self.messageSessions[session][index].text = text
        }
    }

    func stopStreaming() {
        controlTask?.cancel()
        stream.invalidate()
        let token = generation
        controlTask = Task { [weak self] in
            guard let self else { return }
            await self.stream.stopAndDrain()
            guard !Task.isCancelled, self.generation == token else { return }
            self.isLoading = false
            self.controlTask = nil
        }
    }

    func completeStreaming() {
        controlTask?.cancel()
        stream.invalidate()
        let token = generation
        controlTask = Task { [weak self] in
            guard let self else { return }
            await self.stream.stopAndDrain()
            guard !Task.isCancelled, self.generation == token, let fixture,
                  let index = self.messageSessions[self.activeIndex].indices.last,
                  let complete = fixture.sessions[self.activeIndex].messages.last?.text else { return }
            self.messageSessions[self.activeIndex][index].text = complete
            self.controlTask = nil
        }
    }

    func nextSession() {
        guard sessionCount > 1 else { return }
        invalidate()
        activeIndex = (activeIndex + 1) % sessionCount
        preparedForStreaming = false
        stopStreaming()
    }

    func recordAction() { localActions += 1 }

    func invalidate() {
        generation &+= 1
        controlTask?.cancel()
        controlTask = nil
        stream.invalidate()
        isLoading = false
    }
}
