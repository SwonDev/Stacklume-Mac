import SwiftUI
import StacklumeDesignSystem

/// Ajustes de IA: estado del modelo Liquid local y carga/liberación.
struct AISettingsView: View {
    @Environment(\.themePalette) private var palette
    @State private var runner = LocalAIRunner.shared
    /// Autocompletar con IA al añadir un enlace (lo respeta el disparo automático del
    /// editor; el botón manual «Autocompletar con IA» funciona siempre). Por defecto, activado.
    @AppStorage("stacklume.aiAutoEnrich") private var aiAutoEnrich = true
    /// Razonamiento del asistente (cadena de pensamiento). Activado por defecto: el chat
    /// razona en la 1.ª ronda para elegir mejor las herramientas. Desactívalo para
    /// respuestas más directas y rápidas.
    @AppStorage("stacklume.aiThinking") private var aiThinking = true
    /// La web es opcional y explícita: ninguna parte de la biblioteca ni del chat se
    /// envía. Solo sale la consulta de una petición web y se procesa el resultado localmente.
    @AppStorage(AssistantWebAccess.enabledKey) private var webSearchEnabled = true
    /// Fuerza el refresco de la sección «Lo que sé de ti» tras olvidar el perfil.
    @State private var profileRefresh = 0
    @State private var showForgetConfirmation = false

    private var statusText: String {
        switch runner.state {
        case .notLoaded: "No cargado"
        case .downloading(let f): "Descargando… \(Int(f * 100))%"
        case .loading: "Cargando en memoria…"
        case .ready: "Listo"
        case .failed(let m): "Error: \(m)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                EmbeddingGemmaSettingsSection()
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .scaledFont(30, scalesWithText: false)
                        .foregroundStyle(palette.accent)
                        .frame(width: 64, height: 64)
                        .background(
                            palette.background.opacity(0.30),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .stacklumeGlass(
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(palette.accent.opacity(0.34), lineWidth: 0.75)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalAIRunner.modelDisplayName)
                            .stacklumeFont(.title3.weight(.bold)).foregroundStyle(palette.textPrimary)
                        Text("Modelo local on-device · ~\(LocalAIRunner.approxDownloadGB, specifier: "%.1f") GB")
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                    }
                }

                HStack {
                    Text("Estado").foregroundStyle(palette.textSecondary)
                    Spacer()
                    Text(statusText).foregroundStyle(palette.textPrimary).fontWeight(.semibold)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                if case .downloading(let f) = runner.state {
                    ProgressView(value: f).tint(palette.accent)
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        Task { await runner.ensureReady(userInitiated: true) }
                    } label: {
                        Label(runner.isReady ? "Recargar modelo" : "Cargar modelo", systemImage: "play.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .stacklumeButton()
                    .disabled(runner.isBusy)

                    if runner.isReady {
                        Button {
                            runner.deactivate()
                        } label: {
                            Label("Liberar memoria", systemImage: "memorychip")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .stacklumeButton(prominent: false)
                    }
                }
                .stacklumeGlassContainer(spacing: DesignSystem.Spacing.sm)

                Text("El modelo Liquid se ejecuta íntegramente en tu Mac (Apple Silicon, MLX). Si lo tienes en LM Studio, se reutiliza desde ahí; si no, se descarga la primera vez.")
                    .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Label("Memoria y contexto", systemImage: "brain")
                            .stacklumeFont(.callout.weight(.semibold)).foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text(LocalAIRunner.contextWindowLabel)
                            .stacklumeFont(.callout.weight(.bold)).foregroundStyle(palette.readableAccent(on: palette.surface))
                    }
                    Text("El presupuesto se adapta a la memoria de este Mac y reserva espacio para herramientas y respuestas. Conserva hasta \(AssistantConversationStore.maximumMessagesPerSession) mensajes por chat; lo antiguo se recupera mediante memoria semántica local.")
                        .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Toggle(isOn: $aiThinking) {
                        Label("Razonamiento del asistente", systemImage: "brain")
                            .foregroundStyle(palette.textPrimary)
                    }
                    .tint(palette.accent)
                    Text("Cuando está activado, el asistente razona internamente antes de responder para elegir mejor las herramientas. Ese proceso interno no se muestra ni se guarda en el historial.")
                        .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Toggle(isOn: $aiAutoEnrich) {
                        Label("Autocompletar con IA al añadir", systemImage: "sparkles")
                            .foregroundStyle(palette.textPrimary)
                    }
                    .tint(palette.accent)
                    Text("Al escribir la URL de un enlace nuevo, la IA mejora el título, redacta la descripción y propone categoría y etiquetas. Puedes lanzarlo siempre a mano con el botón «Autocompletar con IA» del editor.")
                        .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Toggle(isOn: $webSearchEnabled) {
                        Label("Completar investigaciones con la web", systemImage: "globe")
                            .foregroundStyle(palette.textPrimary)
                    }
                    .tint(palette.accent)
                    Text("Cuando pides investigar recursos, comparar opciones o proponer una aplicación, el asistente puede completar la biblioteca con consultas a DuckDuckGo. Solo envía términos de tu petición; no adjunta tu biblioteca ni tu perfil. Las páginas se procesan en este Mac.")
                        .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Label("Control y seguridad", systemImage: "checkmark.shield")
                        .stacklumeFont(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Las acciones masivas, fusiones y borrados no dependen del modelo: Stacklume calcula su impacto y exige una confirmación explícita antes de ejecutarlas.")
                        .stacklumeFont(.footnote).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))

                profileSection
                    .id(profileRefresh)

                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(WindowBackground())
        .alert("¿Olvidar todo el perfil?", isPresented: $showForgetConfirmation) {
            Button("Olvidar", role: .destructive) {
                EntityGraph.shared.clear()
                profileRefresh += 1
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borrarán los proyectos, intereses y preferencias que el asistente ha aprendido. Esta acción no se puede deshacer.")
        }
    }

    /// «Lo que sé de ti»: el perfil DURADERO que el asistente ha aprendido (grafo de entidades),
    /// solo lectura + botón para olvidarlo. Se actualiza solo a medida que conversas; todo en tu Mac.
    @ViewBuilder
    private var profileSection: some View {
        let facts = EntityGraph.shared.profileLines(limit: 40)
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "person.text.rectangle")
                    .scaledFont(20, scalesWithText: false).foregroundStyle(palette.accent)
                Text("Lo que sé de ti").stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
                Spacer()
                if !facts.isEmpty {
                    Button(role: .destructive) {
                        showForgetConfirmation = true
                    } label: {
                        Label("Olvidar", systemImage: "trash")
                            .stacklumeFont(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                    .themedHelp("Borra todo lo que el asistente ha aprendido sobre ti")
                }
            }
            if facts.isEmpty {
                Text("Aún no he aprendido nada duradero sobre ti. A medida que conversemos recordaré tus proyectos, intereses y preferencias (todo on-device, privado).")
                    .stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(facts, id: \.self) { fact in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 5))
                            .foregroundStyle(palette.accent).padding(.top, 6)
                        Text(fact).stacklumeFont(.callout).foregroundStyle(palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
    }
}
