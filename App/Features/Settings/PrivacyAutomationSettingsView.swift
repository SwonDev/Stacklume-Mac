import SwiftUI
import SwiftData
import StacklumeDesignSystem

/// Centro de consentimiento y revocación para las fronteras que salen del proceso de
/// Stacklume: portapapeles, Spotlight y App Intents. Ningún control cambia el modelo de IA
/// ni el store; únicamente gobierna qué metadatos puede consultar el sistema.
struct PrivacyAutomationSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette

    @AppStorage(FaviconPrivacyPolicy.enabledKey) private var thirdPartyFavicons = true
    @AppStorage(ClipboardMonitor.enabledKey) private var clipboardWatch = false
    @AppStorage(StacklumeSpotlightPolicy.enabledKey) private var spotlightEnabled = true
    @AppStorage(StacklumeSpotlightPolicy.privateContentEnabledKey)
    private var spotlightPrivateContent = false
    @AppStorage(StacklumeAutomationAccess.captureEnabledKey) private var captureEnabled = false
    @AppStorage(StacklumeAutomationAccess.readEnabledKey) private var readEnabled = false
    @AppStorage(StacklumeAutomationAccess.organizeEnabledKey) private var organizeEnabled = false
    @AppStorage(StacklumeAutomationAuditLog.revisionKey) private var auditRevision = 0

    @State private var isUpdatingSpotlight = false
    @State private var spotlightMessage: String?
    @State private var showClearAuditConfirmation = false
    @State private var login = LaunchAtLoginController.shared

    private var readBinding: Binding<Bool> {
        Binding(
            get: { readEnabled },
            set: { allowed in
                readEnabled = allowed
                if !allowed { organizeEnabled = false }
            }
        )
    }

    private var organizeBinding: Binding<Bool> {
        Binding(
            get: { readEnabled && organizeEnabled },
            set: { organizeEnabled = $0 && readEnabled }
        )
    }

    private var recentEvents: [StacklumeAutomationAuditEvent] {
        _ = auditRevision
        return Array(StacklumeAutomationAuditLog.events().prefix(8))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Iniciar con el Mac en la barra de menús", isOn: Binding(
                    get: { login.enabled }, set: { login.setEnabled($0) }))
                if login.needsApproval {
                    Button("Permitir en Ajustes del Sistema…") { login.openSystemSettings() }
                }
                if let message = login.message {
                    Text(message).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
            } header: {
                Label("Inicio y barra de menús", systemImage: "power")
            } footer: {
                Text("Arranca sin abrir la biblioteca ni cargar modelos de IA. Los enlaces que guardes desde la barra reciben metadatos, organización y portada con el mismo proceso de siempre. Con los atajos globales activos, ⌃⌥⌘B abre el guardado rápido desde cualquier app.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            Section {
                Toggle("Completar iconos con Google y DuckDuckGo", isOn: $thirdPartyFavicons)
            } header: {
                Label("Iconos de los enlaces", systemImage: "globe")
            } footer: {
                Text("Completa los iconos que no se pueden descargar del propio sitio. Estos servicios reciben el dominio del enlace, sin su ruta ni su contenido. Los iconos se guardan en la caché local; puedes desactivar este respaldo y seguir usando los ya guardados.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            clipboardSection
            spotlightSection
            shortcutsSection
            activitySection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WindowBackground())
        .onAppear { login.refresh() }
        .confirmationDialog(
            "¿Borrar el historial de automatización?",
            isPresented: $showClearAuditConfirmation,
            titleVisibility: .visible
        ) {
            Button("Borrar historial", role: .destructive) {
                StacklumeAutomationAuditLog.clear()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Solo se eliminarán las últimas marcas locales de actividad. Tus enlaces y permisos no cambiarán.")
        }
        .onChange(of: spotlightEnabled) { _, enabled in
            applySpotlightPolicy(enabled: enabled)
        }
        .onChange(of: spotlightPrivateContent) { _, _ in
            guard spotlightEnabled else { return }
            applySpotlightPolicy(enabled: true)
        }
    }

    private var clipboardSection: some View {
        Section {
            Toggle("Sugerir guardar los enlaces que copio", isOn: $clipboardWatch)
        } header: {
            Label("Portapapeles", systemImage: "doc.on.clipboard")
        } footer: {
            Text("Desactivado por defecto. Stacklume solo lee el contenido cuando detecta un cambio y este permiso está activo. Cerrar la ventana o dejar la app en la barra de menús nunca lo activa por su cuenta.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var spotlightSection: some View {
        Section {
            Toggle("Mostrar mis enlaces en Spotlight", isOn: $spotlightEnabled)
                .disabled(isUpdatingSpotlight)
            Toggle(
                "Incluir descripciones, notas y texto de documentos",
                isOn: $spotlightPrivateContent
            )
            .disabled(!spotlightEnabled || isUpdatingSpotlight)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Reconstruir índice ahora") {
                    applySpotlightPolicy(enabled: spotlightEnabled)
                }
                .disabled(isUpdatingSpotlight)

                if isUpdatingSpotlight {
                    ProgressView()
                        .controlSize(.small)
                    Text("Aplicando…")
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            if let spotlightMessage {
                Label(spotlightMessage, systemImage: "checkmark.shield")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityLabel(spotlightMessage)
            }
        } header: {
            Label("Búsqueda del sistema", systemImage: "magnifyingglass")
        } footer: {
            Text("El índice permanece en este Mac. Por defecto solo contiene título, URL, plataforma, colección y etiquetas; el contenido privado requiere tu consentimiento explícito. Al cambiar el nivel, Stacklume reconstruye el índice para retirar los atributos anteriores.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var shortcutsSection: some View {
        Section {
            Toggle("Permitir guardar enlaces desde Atajos", isOn: $captureEnabled)
            Toggle("Permitir consultar mi biblioteca", isOn: readBinding)
            Toggle("Permitir organizar enlaces existentes", isOn: organizeBinding)
                .disabled(!readEnabled)
        } header: {
            Label("Atajos, Siri y Apple Intelligence", systemImage: "shortcut")
        } footer: {
            Text("La captura solo acepta URLs públicas válidas, las guarda mediante el pipeline normal de Stacklume y no consulta tu biblioteca existente. Consultar devuelve metadatos acotados; organizar permite cambiar favoritos, lectura, archivado, colección y etiquetas, pero nunca borrar. Ninguna acción obtiene notas, resaltados, texto offline, rutas locales ni acceso directo al store. Revocar detiene futuras ejecuciones, pero no puede borrar resultados que ya hayas guardado en otros atajos.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var activitySection: some View {
        Section {
            if recentEvents.isEmpty {
                Label("Todavía no hay actividad externa registrada.", systemImage: "clock.badge.checkmark")
                    .foregroundStyle(palette.textSecondary)
            } else {
                ForEach(recentEvents) { event in
                    auditRow(event)
                }
                Button("Borrar historial…", role: .destructive) {
                    showClearAuditConfirmation = true
                }
            }
        } header: {
            Label("Actividad reciente", systemImage: "list.bullet.clipboard")
        } footer: {
            Text("Se conservan como máximo 100 eventos: fecha, capacidad, resultado y cantidad. El registro nunca guarda URLs, títulos, búsquedas ni contenido de tus enlaces.")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func auditRow(_ event: StacklumeAutomationAuditEvent) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: event.outcome == .completed ? "checkmark.circle.fill" : "hand.raised.fill")
                .foregroundStyle(event.outcome == .completed ? palette.accent : palette.textSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(actionTitle(event.action))
                    .stacklumeFont(.callout.weight(.medium))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(2)
                Text("\(outcomeTitle(event.outcome)) · \(capabilityTitle(event.capability)) · \(event.date.formatted(date: .abbreviated, time: .shortened))")
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Text(event.itemCount == 1 ? "1 elemento" : "\(event.itemCount) elementos")
                .stacklumeFont(.caption.monospacedDigit())
                .foregroundStyle(palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func applySpotlightPolicy(enabled: Bool) {
        guard !isUpdatingSpotlight else { return }
        isUpdatingSpotlight = true
        spotlightMessage = nil
        Task { @MainActor in
            await Task.yield()
            if enabled {
                SpotlightIndexer.reindexAll(in: context, force: true)
                spotlightMessage = spotlightPrivateContent
                    ? "Reconstrucción con contenido privado solicitada."
                    : "Reconstrucción solo con metadatos solicitada."
            } else {
                SpotlightIndexer.clearAll()
                spotlightMessage = "Retirada del índice de Spotlight solicitada."
            }
            isUpdatingSpotlight = false
        }
    }

    private func actionTitle(_ action: StacklumeAutomationAction) -> String {
        switch action {
        case .captureOne: "Guardar un enlace"
        case .captureBatch: "Guardar varios enlaces"
        case .search: "Buscar enlaces"
        case .getBookmarks: "Obtener enlaces"
        case .openRandom: "Abrir un enlace al azar"
        case .openUnread: "Abrir el último sin leer"
        case .openBookmark: "Abrir un enlace"
        case .changeState: "Cambiar estado"
        case .moveToCollection: "Mover a una colección"
        case .editTags: "Editar etiquetas"
        }
    }

    private func capabilityTitle(_ capability: StacklumeAutomationCapability) -> String {
        switch capability {
        case .capture: "captura"
        case .read: "consulta"
        case .organize: "organización"
        }
    }

    private func outcomeTitle(_ outcome: StacklumeAutomationAuditOutcome) -> String {
        switch outcome {
        case .completed: "Permitida"
        case .blocked: "Bloqueada"
        }
    }
}
