import Foundation

extension LocalAIRunner: CanonicalXAuditRunner {
    var diagnosticState: CanonicalObservedRunnerState {
        switch state {
        case .notLoaded: .notLoaded
        case .downloading: .downloading
        case .loading: .loading
        case .ready: .ready
        case .failed: .failed
        }
    }
    var diagnosticModelAvailable: Bool {
        // No basta una preferencia de descarga antigua: exige presencia real.
        guard Self.modelID == "LiquidAI/LFM2.5-8B-A1B-MLX-8bit", let directory = Self.installedModelDirectory(),
              directory.standardizedFileURL == Self.modelDirectory().standardizedFileURL,
              let template = try? Data(contentsOf: directory.appendingPathComponent("chat_template.jinja")),
              template.count <= 8_192 else { return false }
        return CanonicalWire.hash(template) == "f434e8c96e6c0a63a022a3ad0a299bb94e58aa90e3c9ebe65034f8e8c6188aa9"
    }
    var diagnosticDeactivated: Bool { isDeactivated }
    var diagnosticBackgroundIdle: Bool { Self.canRunBackgroundWork }
}

extension CanonicalXAuditCoordinator {
    static let shared = CanonicalXAuditCoordinator(
        arguments: Array(CommandLine.arguments.dropFirst()),
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StacklumeDevelopment/lfm-audit/runs"),
        runner: LocalAIRunner.shared,
        identity: { try CanonicalNativeIdentity.current() },
        installed: {
            guard let executable = Bundle.main.executableURL,
                  executable.path == CanonicalArmedTicket.executable,
                  let identifier = Bundle.main.bundleIdentifier,
                  let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { throw CanonicalTicketError.identity }
            return .init(executablePath: executable.path,
                executableSHA256: CanonicalWire.hash(try Data(contentsOf: executable)),
                bundleIdentifier: identifier, bundleVersion: version)
        },
        fixture: {
            let originals = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StacklumeDevelopment/lfm-audit/fixtures")
            return try CanonicalAuditFixture.prepare(sourceData: Data(contentsOf: originals.appendingPathComponent("mygo-public-source.txt")),
                candidatesData: Data(contentsOf: originals.appendingPathComponent("candidates-original-x91.json")))
        })
}
