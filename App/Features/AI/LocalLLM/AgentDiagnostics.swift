import Foundation
import OSLog

/// Registro de diagnóstico local del agente Liquid. Está DESACTIVADO por defecto incluso
/// en Debug, porque mensajes, URLs y resultados pueden contener información privada.
/// Archivo: Application Support/StacklumeLLM/agent-debug.log
final class AgentDiagnostics: @unchecked Sendable {
    enum TurnOutcome: String, Sendable {
        case completed
        case awaitingConfirmation
        case toolLimit
        case cancelled
        case failed
    }

    enum PersistenceEvent: String, Sendable {
        case recoveredBackup = "recovered-backup"
        case saveFailed = "save-failed"
    }

    static let shared = AgentDiagnostics()
    private let lock = NSLock()
    private let healthLog = Logger(subsystem: "com.swondev.stacklume", category: "AssistantHealth")
    private static let enabledKey = "stacklume.developer.agentDiagnosticsEnabled"
    private static let maximumBytes = 2 * 1_024 * 1_024

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StacklumeLLM", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("agent-debug.log")
    }()

    private init() {
        #if DEBUG
        if !UserDefaults.standard.bool(forKey: Self.enabledKey) {
            try? FileManager.default.removeItem(at: url)
        }
        #endif
    }

    func log(_ message: String) {
        // SOLO metadatos en desarrollo. Los llamadores no pasan mensajes, URLs, títulos,
        // resultados ni respuestas: incluso al activar el diagnóstico el contenido privado
        // de la biblioteca nunca debe acabar en este archivo.
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        lock.lock(); defer { lock.unlock() }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maximumBytes {
            try? FileManager.default.removeItem(at: url)
        }
        let safe = AssistantActionPolicy.sanitizedUserInput(message)
        let line = "[\(Date())] \(String(safe.prefix(4_000)))\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    /// Marca el inicio de una nueva petición (separador visual).
    func mark(_ title: String) {
        log("──────────── \(title) ────────────")
    }

    /// Telemetría local agregada en Unified Logging. No contiene prompts, URLs, nombres,
    /// resultados ni identificadores; sirve para localizar respuestas lentas o bucles.
    func recordTurn(
        duration: TimeInterval,
        outputCharacters: Int,
        rounds: Int,
        toolCalls: Int,
        outcome: TurnOutcome
    ) {
        healthLog.info(
            "turn outcome=\(outcome.rawValue, privacy: .public) durationMs=\(Int(duration * 1_000), privacy: .public) outputChars=\(outputCharacters, privacy: .public) rounds=\(rounds, privacy: .public) toolCalls=\(toolCalls, privacy: .public)"
        )
    }

    func recordPersistence(_ event: PersistenceEvent) {
        healthLog.notice("history event=\(event.rawValue, privacy: .public)")
    }

    func recordResearchReview(_ metrics: AssistantResearchReviewMetrics) {
        let classes = metrics.issueClasses.map(\.rawValue).joined(separator: ",")
        healthLog.info("research stage=\(metrics.stage.rawValue, privacy: .public) chars=\(metrics.characters, privacy: .public) sources=\(metrics.sourceCount, privacy: .public) read=\(metrics.readSourceCount, privacy: .public) unknownCitations=\(metrics.unknownCitations, privacy: .public) issues=\(metrics.issueCount, privacy: .public) classes=\(classes, privacy: .public) truncated=\(metrics.reachedLengthLimit, privacy: .public)")
    }
}
