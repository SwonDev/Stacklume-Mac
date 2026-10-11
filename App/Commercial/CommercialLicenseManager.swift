import Foundation
import Observation

enum CommercialLicenseAccessError: LocalizedError, Sendable {
    case activationRequired

    var errorDescription: String? {
        "Activa Stacklume para Mac antes de usar esta acción. Abre la app e introduce tu clave de licencia."
    }
}

@MainActor
enum CommercialLicenseAccessPolicy {
    static func requireAccess() throws {
        guard CommercialLicenseManager.shared.hasAccess else {
            throw CommercialLicenseAccessError.activationRequired
        }
    }
}

@MainActor
@Observable
final class CommercialLicenseManager {
    static let shared = CommercialLicenseManager()

    let configuration: CommercialLicenseConfiguration
    private let store: CommercialLicenseStore
    private let client: PolarLicenseClient
    private var receipt: CommercialLicenseReceipt?
    private var didStart = false

    private(set) var hasAccess: Bool
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    var licenseKeyInput = ""

    init(
        configuration: CommercialLicenseConfiguration = .current,
        store: CommercialLicenseStore = CommercialLicenseStore(),
        client: PolarLicenseClient = PolarLicenseClient()
    ) {
        self.configuration = configuration
        self.store = store
        self.client = client

        if !configuration.isCommercialBuild {
            hasAccess = true
            receipt = nil
            return
        }

        do {
            let stored = try store.load()
            receipt = stored
            hasAccess = stored?.grantsAccess() == true
        } catch {
            receipt = nil
            hasAccess = false
            errorMessage = error.localizedDescription
        }
    }

    var hasStoredLicense: Bool { receipt != nil }

    var maskedLicenseKey: String? {
        guard let key = receipt?.key, key.count > 12 else { return nil }
        return "\(key.prefix(8))••••\(key.suffix(4))"
    }

    var lastValidatedAt: Date? { receipt?.validatedAt }

    func start() {
        guard !didStart else { return }
        didStart = true
        guard configuration.isCommercialBuild else { return }
        guard configuration.isComplete else {
            hasAccess = false
            errorMessage = PolarLicenseClientError.invalidConfiguration.localizedDescription
            return
        }
        guard let receipt else { return }

        if hasAccess {
            StacklumeUpdater.shared.start()
            statusMessage = "Licencia válida. Comprobando su estado…"
        }
        Task { [weak self] in
            await self?.refreshLicense()
        }
    }

    func activate() {
        guard !isWorking else { return }
        let key = CommercialLicenseInput.normalizedKey(licenseKeyInput)
        guard CommercialLicenseInput.isPlausibleKey(key) else {
            errorMessage = "Introduce la clave completa que recibiste tras la compra."
            return
        }
        guard configuration.isComplete else {
            errorMessage = PolarLicenseClientError.invalidConfiguration.localizedDescription
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = "Activando este Mac…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let newReceipt = try await client.activate(
                    key: key,
                    configuration: configuration,
                    installationLabel: Self.installationLabel()
                )
                try store.save(newReceipt)
                receipt = newReceipt
                hasAccess = true
                licenseKeyInput = ""
                statusMessage = "Licencia activada correctamente."
                StacklumeUpdater.shared.start()
                enableBackgroundFeatures()
            } catch {
                hasAccess = false
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
            isWorking = false
        }
    }

    func refreshLicense() async {
        guard configuration.isCommercialBuild, let currentReceipt = receipt else { return }
        isWorking = true
        errorMessage = nil
        do {
            let refreshed = try await client.validate(
                receipt: currentReceipt,
                configuration: configuration
            )
            try store.save(refreshed)
            receipt = refreshed
            hasAccess = true
            statusMessage = "Licencia verificada."
            StacklumeUpdater.shared.start()
            enableBackgroundFeatures()
        } catch let error as PolarLicenseClientError {
            if error.isAuthoritativeRejection {
                try? store.delete()
                receipt = nil
                hasAccess = false
                disableBackgroundFeatures()
                errorMessage = error.localizedDescription
                statusMessage = nil
            } else if currentReceipt.grantsAccess() {
                hasAccess = true
                statusMessage = "Sin conexión: usando la validación segura guardada."
                StacklumeUpdater.shared.start()
                enableBackgroundFeatures()
            } else {
                hasAccess = false
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        } catch {
            if currentReceipt.grantsAccess() {
                hasAccess = true
                statusMessage = "Sin conexión: usando la validación segura guardada."
                StacklumeUpdater.shared.start()
                enableBackgroundFeatures()
            } else {
                hasAccess = false
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
        isWorking = false
    }

    func deactivateThisMac() {
        guard !isWorking, let currentReceipt = receipt else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Liberando esta activación…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.deactivate(
                    receipt: currentReceipt,
                    configuration: configuration
                )
                try store.delete()
                receipt = nil
                hasAccess = false
                statusMessage = nil
                disableBackgroundFeatures()
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
            isWorking = false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private static func installationLabel() -> String {
        let defaults = UserDefaults.standard
        let key = "stacklume.commercial.installationID"
        let identifier: String
        if let stored = defaults.string(forKey: key), UUID(uuidString: stored) != nil {
            identifier = stored
        } else {
            identifier = UUID().uuidString
            defaults.set(identifier, forKey: key)
        }
        return "Stacklume Mac \(identifier.prefix(8))"
    }

    private func enableBackgroundFeatures() {
        MenuBarController.shared.start()
        NotificationCenter.default.post(name: .stacklumeReloadHotKey, object: nil)
    }

    private func disableBackgroundFeatures() {
        MenuBarController.shared.stop()
        NotificationCenter.default.post(name: .stacklumeReloadHotKey, object: nil)
    }
}
