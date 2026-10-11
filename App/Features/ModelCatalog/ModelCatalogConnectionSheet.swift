import SwiftUI
import StacklumeDesignSystem

struct ModelCatalogConnectionSheet: View {
    let provider: ModelCatalogProvider
    let connectionStatus: ModelCatalogConnectionStatus
    let onChanged: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var token = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showsDisconnectConfirmation = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var isAuthorizing = false
    @FocusState private var tokenFocused: Bool

    var body: some View {
        EditorScaffold(title: "Cuenta · \(provider.title)", confirmTitle: isWorking ? "Comprobando…" : "Comprobar y guardar", canConfirm: !token.isEmpty && !isWorking, onCancel: { connectionTask?.cancel(); token = ""; dismiss() }, onConfirm: connect) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if [.checking, .authorizationRequired, .unavailable, .accountUnavailable, .accessUnverified].contains(connectionStatus) {
                        ModelCatalogFormSection("Acceso al Llavero") {
                            Text(connectionStatus.message).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            Button("Autorizar acceso") { authorizeAccess() }.stacklumeButton().disabled(isWorking)
                            Text("macOS puede pedir permiso para leer una clave guardada. Responde al diálogo del sistema; no necesitas volver a pegarla. El catálogo público continúa disponible.")
                                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        }
                    }
                    ModelCatalogFormSection("Tu clave de API") {
                        ModelCatalogField("Clave de API de \(provider.title)", text: $token, secure: true, externalFocus: $tokenFocused)
                            .disabled(isWorking).accessibilityLabel("Clave de API de \(provider.title)")
                        Text(connectionStatus.hasSavedCredential ? "Ya hay una clave guardada. Puedes autorizar el acceso o introducir otra para sustituirla tras comprobarla." : "La clave se comprueba con el proveedor y se guarda en el Llavero de macOS, separada de las credenciales de otras aplicaciones.")
                            .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        if let url = provider.tokenSettingsURL { Link("Obtener mi clave en \(provider.title)", destination: url).foregroundStyle(palette.readableAccent(on: palette.surface)) }
                        if provider == .huggingFace {
                            Text("Usa un token con permisos de lectura para los repositorios que quieras consultar. Los modelos privados y gated mantienen sus restricciones.")
                                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        } else {
                            Text("La validación consulta tus favoritos, que requieren autenticación. La visibilidad de contenido para adultos depende de los ajustes y permisos que permita Civitai.")
                                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        }
                    }
                    if let error { ModelCatalogFormSection { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(palette.textPrimary) } }
                    if isWorking { ModelCatalogFormSection { ProgressView(isAuthorizing ? "Esperando permiso de macOS y comprobando la cuenta…" : "Comprobando el acceso…").tint(palette.accent) } }
                    if connectionStatus.hasSavedCredential {
                        ModelCatalogFormSection {
                            Button("Eliminar clave de Stacklume…", role: .destructive) { showsDisconnectConfirmation = true }
                                .disabled(isWorking)
                            Text("Después podrás seguir consultando el catálogo público.").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .background(palette.background)
        }
        .frame(minWidth: 340, idealWidth: 520, maxWidth: 620, minHeight: 320, idealHeight: 460, maxHeight: 660)
        .task { tokenFocused = !connectionStatus.hasSavedCredential }
        .onDisappear { connectionTask?.cancel(); token = "" }
        .alert("¿Eliminar la clave de \(provider.title) de Stacklume?", isPresented: $showsDisconnectConfirmation) {
            Button("Eliminar clave", role: .destructive) { disconnect() }
            Button("Cancelar", role: .cancel) { }
        } message: { Text("Solo se elimina la credencial guardada por Stacklume para este proveedor.") }
    }

    private func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelCatalogRequest.validToken(value) else { error = ModelCatalogError.invalidToken.localizedDescription; return }
        isWorking = true; isAuthorizing = false; error = nil
        connectionTask?.cancel()
        connectionTask = Task {
            do {
                _ = try await ModelCatalogClient.shared.connect(provider, token: value)
                try Task.checkCancellation()
                token = ""; await onChanged(); dismiss()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isWorking = false
        }
    }

    private func authorizeAccess() {
        isWorking = true; isAuthorizing = true; error = nil
        connectionTask?.cancel()
        connectionTask = Task {
            do {
                _ = try await ModelCatalogClient.shared.authorizeAccess(provider)
                try Task.checkCancellation()
                await onChanged(); dismiss()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isWorking = false; isAuthorizing = false
        }
    }

    private func disconnect() {
        isWorking = true; error = nil
        connectionTask?.cancel()
        connectionTask = Task {
            do { try await ModelCatalogClient.shared.disconnect(provider); token = ""; await onChanged(); dismiss() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isWorking = false
        }
    }
}
