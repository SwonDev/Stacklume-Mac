import Foundation
import OSLog
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import MLX
import Darwin

extension Notification.Name {
    static let stacklumeCriticalMemoryPressure = Notification.Name("stacklume.memory.critical")
}

private let aiLog = Logger(subsystem: "com.swondev.stacklume", category: "LocalAI")

/// Gestiona el modelo de IA local (texto) vía MLX Swift.
/// Descarga los archivos con un descargador propio (URLSession, progreso real),
/// y carga el modelo desde el directorio local. La operación corre fuera del
/// MainActor. Requiere dispositivo real (MLX usa Metal).
@MainActor
@Observable
final class LocalAIRunner {
    static let shared = LocalAIRunner()

    // Modelo LIQUID elegido por el usuario para Mac: LFM2.5-8B-A1B (MoE 8B/1B activo),
    // MLX 8-bit (~8.4 GB). Se conserva el modelo elegido y se limita la caché auxiliar.
    static let modelID = "LiquidAI/LFM2.5-8B-A1B-MLX-8bit"
    static let modelDisplayName = "LFM2.5-8B-A1B (Liquid)"
    static let approxDownloadGB = 8.4

    enum State: Equatable {
        case notLoaded
        case downloading(Double)   // fracción 0–1
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .notLoaded {
        didSet { synchronizeEmbeddingWorkload(); scheduleIdleRelease() }
    }
    private var container: ModelContainer?
    /// Carga compartida: todas las llamadas concurrentes esperan el MISMO trabajo. Antes,
    /// la segunda recibía `nil` y la UI mostraba un falso error mientras el modelo cargaba.
    private var loadAttempt: LocalModelLoadAttempt<ModelContainer>?
    private var loadAdmission = LocalModelLoadAdmission()
    /// `true` mientras el chat está generando una respuesta (lo marca LiquidConversation).
    /// Evita descargar el modelo de memoria en mitad de una generación.
    var isGenerating = false {
        didSet { synchronizeEmbeddingWorkload(); scheduleIdleRelease() }
    }
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var idleRelease: Task<Void, Never>?
    @ObservationIgnored private var oneShotTasks: [UUID: Task<String?, Never>] = [:]
    @ObservationIgnored private var cancelledOneShotRequests = Set<UUID>()
    private var oneShotRequests = 0 {
        didSet { synchronizeEmbeddingWorkload(); scheduleIdleRelease() }
    }
    private var unloadWhenIdle = false
    private var embeddingSearchReservations = 0
    @ObservationIgnored private var conversationRounds = Set<UUID>() {
        didSet { synchronizeEmbeddingWorkload(); scheduleIdleRelease() }
    }
    private var hasActiveInference: Bool {
        isGenerating || oneShotRequests > 0 || !conversationRounds.isEmpty
    }

    /// Flag de "descargado por completo", KEY POR MODELO: al cambiar de modelID, la clave
    /// cambia → se considera no descargado → se descarga el modelo nuevo.
    private var downloadedKey: String { "stacklume.modelDownloaded." + Self.modelID }
    var isDownloaded: Bool {
        get { UserDefaults.standard.bool(forKey: downloadedKey) }
        set { UserDefaults.standard.set(newValue, forKey: downloadedKey) }
    }

    var isReady: Bool { if case .ready = state { return true }; return false }
    var isBusy: Bool {
        if loadAttempt != nil { return true }
        return switch state { case .downloading, .loading: true; default: false }
    }

    /// ¿El modelo está disponible para usarse SIN una nueva descarga? Comprueba la VERDAD
    /// del terreno —cargado en memoria (`isReady`), marcado como descargado, o PRESENTE en
    /// disco (LM Studio / caché de HuggingFace / carpeta propia)— en vez de fiarse solo del
    /// flag `isDownloaded` de UserDefaults, que puede quedar a `false` aunque el modelo esté
    /// instalado y funcionando (p. ej. si se usó vía una instalación externa que nunca lo
    /// marcó). Úsalo para decidir si hace falta OFRECER una descarga: si esto es `true`, NO.
    var isAvailable: Bool {
        isReady || isDownloaded || Self.installedModelDirectory() != nil
    }

    /// Desactivado MANUALMENTE por el usuario (pulsó «Descargar de la memoria» en
    /// Ajustes). Mientras sea `true`, el modelo NO se carga de forma automática en
    /// ninguna sección (ni precarga al abrir, ni autocompletado, ni chat): es como
    /// apagar la IA local. Solo se reactiva pulsando «Cargar modelo». Persiste entre
    /// sesiones, así que la decisión del usuario se respeta tras cerrar la app.
    private static let deactivatedKey = "stacklume.localAI.deactivated"
    private(set) var isDeactivated: Bool = UserDefaults.standard.bool(forKey: deactivatedKey) {
        didSet { UserDefaults.standard.set(isDeactivated, forKey: Self.deactivatedKey) }
    }

    private init() {
        Memory.cacheLimit = 64 * 1_024 * 1_024
        synchronizeEmbeddingWorkload()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { @Sendable [weak self] in
            var level: Int32 = 1
            var size = MemoryLayout<Int32>.size
            let read = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
            guard read != 0 || level != 1 else { return }
            let critical = read != 0 || level >= 4
            Memory.clearCache()
            Task { @MainActor in
                var effectiveLevel = level
                var effectiveRead = read
                if !critical {
                    var currentSize = MemoryLayout<Int32>.size
                    effectiveRead = sysctlbyname("kern.memorystatus_vm_pressure_level", &effectiveLevel, &currentSize, nil, 0)
                    guard effectiveRead != 0 || effectiveLevel != 1 else { return }
                }
                let effectiveCritical = critical || effectiveRead != 0 || effectiveLevel >= 4
                if effectiveCritical { NotificationCenter.default.post(name: .stacklumeCriticalMemoryPressure, object: nil) }
                if effectiveCritical, let self {
                    self.cancelledOneShotRequests.formUnion(self.oneShotTasks.keys)
                }
                if !effectiveCritical, self?.loadAttempt != nil { return }
                self?.unload(loadError: effectiveRead == 0 ? LocalModelLoadingError.memoryPressure(effectiveLevel) : LocalModelLoadingError.unknownMemoryPressure)
                try? await EmbeddingGemmaRuntime.shared.releaseModelMemory()
            }
        }
        pressureSource = source
        source.resume()
    }

    private func synchronizeEmbeddingWorkload() {
        let marker = EmbeddingGemmaRuntime.root.appendingPathComponent("text-inference-active")
        if hasActiveInference || state == .loading {
            try? PrivateFileIO.write(Data(String(ProcessInfo.processInfo.processIdentifier).utf8), to: marker)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        idleRelease = nil
        guard !hasActiveInference else { return }
        if unloadWhenIdle { unload(); return }
        guard isReady else { return }
        idleRelease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(MenuBarController.shared.isMenuBarOnly ? 5 : 180)) } catch { return }
            guard let self, !self.hasActiveInference, self.isReady else { return }
            self.unload()
        }
    }

    nonisolated private static func memoryPressureLevel() -> Int32? {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    private static var memoryIsUnderPressure: Bool { memoryPressureLevel() != 1 }

    static var canRunBackgroundWork: Bool {
        !MenuBarController.shared.isMenuBarOnly && !memoryIsUnderPressure
            && !shared.hasActiveInference && !shared.isBusy && shared.embeddingSearchReservations == 0
    }

    /// Espera la inferencia en curso y libera sus pesos antes de recuperar fuentes.
    /// La reserva impide que el enriquecido vuelva a cargar MLX durante esa búsqueda.
    func withEmbeddingSearch<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        while hasActiveInference || isBusy {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        embeddingSearchReservations += 1
        defer { embeddingSearchReservations -= 1 }
        unload()
        return try await operation()
    }

    /// La cancelación de la UI no libera esta reserva: la ronda la devuelve al
    /// terminar el stream, cuando ya puede soltar sus propias referencias al modelo.
    func beginConversationRound() async -> UUID? {
        while embeddingSearchReservations > 0 || !conversationRounds.isEmpty || oneShotRequests > 0 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        let ticket = UUID()
        conversationRounds.insert(ticket)
        return ticket
    }

    func endConversationRound(_ ticket: UUID) {
        conversationRounds.remove(ticket)
    }

    func ensureReadyForConversation() async -> ModelContainer? {
        while embeddingSearchReservations > 0 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        isGenerating = true
        return await ensureReady()
    }

    /// Carpeta propia donde se descarga el modelo si no se encuentra ya instalado.
    static func ownModelDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = modelID.split(separator: "/").last.map(String.init) ?? "model"
        return base.appendingPathComponent("StacklumeLLM/\(name)", isDirectory: true)
    }

    /// Compatibilidad con el código existente (descarga/limpieza usan la carpeta propia).
    static func modelDirectory() -> URL { ownModelDirectory() }

    /// ¿Hay un modelo MLX completo en `dir`? (config + tokenizer + pesos).
    static func isModelComplete(at dir: URL) -> Bool {
        let fm = FileManager.default
        let config = dir.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: config.path) else { return false }
        let hasTokenizer = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.model").path)
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasWeights = entries.contains { $0.hasSuffix(".safetensors") }
        return hasTokenizer && hasWeights
    }

    /// Resuelve de dónde cargar el modelo: 1) LM Studio del usuario, 2) caché de
    /// HuggingFace, 3) carpeta propia. `nil` si no está en ninguna (habrá que descargar).
    static func installedModelDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lmStudio = home.appendingPathComponent(".lmstudio/models/\(modelID)", isDirectory: true)
        if isModelComplete(at: lmStudio) { return lmStudio }
        let hfName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let snapshots = home.appendingPathComponent(".cache/huggingface/hub/\(hfName)/snapshots", isDirectory: true)
        if let subs = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
           let snap = subs.first(where: { isModelComplete(at: $0) }) {
            return snap
        }
        if isModelComplete(at: ownModelDirectory()) { return ownModelDirectory() }
        return nil
    }

    /// Prepara el modelo (descarga si hace falta + carga en memoria).
    ///
    /// `userInitiated: true` = el usuario pulsó explícitamente «Cargar modelo»: esto
    /// REACTIVA la IA local (limpia `isDeactivated`) y carga. Las llamadas automáticas
    /// (precarga al abrir, autocompletado, chat) usan `false`: si el usuario desactivó
    /// la IA manualmente, NO se carga sola y se devuelve `nil`.
    @discardableResult
    func ensureReady(userInitiated: Bool = false, observer: OneShotObserver? = nil) async -> ModelContainer? {
        if userInitiated {
            isDeactivated = false
            loadAdmission.explicitRequest(hasPendingAttempt: loadAttempt != nil)
        }
        guard !Task.isCancelled, !isDeactivated else { return nil }
        if let container { scheduleIdleRelease(); return container }
        if let attempt = loadAttempt { return await attempt.value() }
        guard !loadAdmission.isBlocked else { return nil }

        let control = LocalModelLoadControl()
        let identifier = UUID()
        guard let deviceBudget = GPU.maxRecommendedWorkingSetBytes() else {
            state = .failed("No he podido consultar el presupuesto de memoria de Metal. Reintenta la carga desde Ajustes › IA.")
            return nil
        }
        // Reserva la otra mitad para macOS y la app; Metal puede recomendar menos.
        let memoryBudget = min(deviceBudget, Int(ProcessInfo.processInfo.physicalMemory / 2))
        guard let policy = try? ModelLoadingPolicy(maximumConcurrentGroups: 1,
            targetBytesPerGroup: 256 * 1_024 * 1_024,
            guardOperation: {
                try control.checkLoadingPressure(pressure: Self.memoryPressureLevel,
                                                 workingSetIsSafe: { Self.loadingMemoryFits(budget: memoryBudget) },
                                                 releaseCache: { Memory.clearCache() })
            },
            observer: { event in
                observer?.recordLoading?(.init(loadID: identifier, sequence: event.sequence,
                    stage: event.stage, groupIndex: event.groupIndex, groupCount: event.groupCount))
            }) else { return nil }
        let attempt = LocalModelLoadAttempt<ModelContainer>(id: identifier, control: control,
            cancelPolicy: { policy.cancel() })
        loadAttempt = attempt
        attempt.register { [weak self] in
            guard let self else { return nil }
            return await self.prepareModel(attempt: attempt, policy: policy, memoryBudget: memoryBudget, observer: observer)
        }
        let result = await attempt.value()
        // La reserva sigue publicada mientras el loader y sus hijas se drenan.
        if loadAttempt?.id == attempt.id { loadAttempt = nil }
        return result
    }

    private func prepareModel(attempt: LocalModelLoadAttempt<ModelContainer>, policy: ModelLoadingPolicy,
                              memoryBudget: Int, observer: OneShotObserver?) async -> ModelContainer? {
        do {
            try attempt.control.check(pressure: Self.memoryPressureLevel)
            guard attempt.canPublish(activeID: loadAttempt?.id), !isDeactivated else { throw CancellationError() }
            while embeddingSearchReservations > 0 {
                try attempt.control.check(pressure: Self.memoryPressureLevel)
                guard attempt.canPublish(activeID: loadAttempt?.id), !isDeactivated else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(100))
                try attempt.control.check(pressure: Self.memoryPressureLevel)
                guard attempt.canPublish(activeID: loadAttempt?.id), !isDeactivated else { throw CancellationError() }
            }
        } catch { return finishAbortedLoad(error, attempt: attempt) }
        if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity, bytes < 3 * 1_024 * 1_024 * 1_024 {
            state = .failed("El disco necesita al menos 3 GB disponibles para que macOS pueda gestionar la memoria del modelo local.")
            return nil
        }
        let alreadyDownloaded = isDownloaded
        state = alreadyDownloaded ? .loading : .downloading(0)
        aiLog.info("ensureReady inicio (descargado=\(alreadyDownloaded))")

        do {
            // Si el modelo ya está instalado (LM Studio / HF / carpeta propia), cargar
            // desde ahí SIN descargar. Si no, descargar a la carpeta propia.
            let dir: URL
            if let installed = Self.installedModelDirectory() {
                dir = installed
                isDownloaded = true
                aiLog.info("Modelo Liquid encontrado en \(installed.path, privacy: .public)")
            } else {
                let target = Self.ownModelDirectory()
                _ = try await ModelDownloader().download(repoID: Self.modelID, to: target) { fraction in
                    Task { @MainActor in
                        guard self.loadAttempt?.id == attempt.id, attempt.control.terminalError == nil,
                              case .downloading = self.state else { return }
                        self.state = .downloading(min(fraction, 1))
                    }
                }
                isDownloaded = true
                dir = target
            }

            try attempt.control.check(pressure: Self.memoryPressureLevel)
            guard attempt.canPublish(activeID: loadAttempt?.id), !isDeactivated else { throw CancellationError() }
            state = .loading
            try await EmbeddingGemmaRuntime.shared.releaseModelMemory()
            try attempt.control.check(pressure: Self.memoryPressureLevel)
            Memory.clearCache()
            let result = try await Self.loadLocal(directory: dir, policy: policy)
            try attempt.control.checkResidentPressure(pressure: Self.memoryPressureLevel,
                workingSetIsSafe: { Self.loadingMemoryFits(budget: memoryBudget) })
            guard attempt.canPublish(activeID: loadAttempt?.id), !isDeactivated, !policy.isCancelled else { throw CancellationError() }
            LiquidSessionConfiguration.observe(observer, at: .afterload)
            try attempt.control.checkResidentPressure(pressure: Self.memoryPressureLevel,
                workingSetIsSafe: { Self.loadingMemoryFits(budget: memoryBudget) })
            guard attempt.canPublish(activeID: loadAttempt?.id), !isDeactivated, !policy.isCancelled else { throw CancellationError() }
            container = result
            state = .ready
            aiLog.info("modelo listo")
            return result
        } catch {
            if let stopped = attempt.control.terminalError { return finishAbortedLoad(stopped, attempt: attempt) }
            if error is CancellationError || error is LocalModelLoadingError {
                return finishAbortedLoad(error, attempt: attempt)
            }
            guard loadAttempt?.id == attempt.id else { return nil }
            let detail = String(describing: error)
            aiLog.error("FALLO: \(detail, privacy: .public)")
            state = .failed(friendlyError(error))
            return nil
        }
    }

    private func finishAbortedLoad(_ error: any Error, attempt: LocalModelLoadAttempt<ModelContainer>) -> ModelContainer? {
        guard loadAttempt?.id == attempt.id else { return nil }
        attempt.cancel(error)
        loadAdmission.block()
        if error is LocalModelLoadingError {
            if error as? LocalModelLoadingError == .unknownMemoryPressure {
                state = .failed("No he podido consultar el estado de la memoria de macOS. Reintenta la carga desde Ajustes › IA.")
            } else if error as? LocalModelLoadingError == .workingSetBudgetExceeded {
                state = .failed("El modelo local ha superado el presupuesto de memoria de Stacklume en este Mac. La biblioteca y la búsqueda siguen disponibles.")
            } else {
                state = .failed("El Mac necesita liberar memoria antes de cargar el modelo local. Reintenta cuando termine el trabajo de otras aplicaciones.")
            }
        } else { state = .notLoaded }
        return nil
    }

    /// Solicita prioridad background para la carga fuera del MainActor. La policy
    /// se instala dentro del task detached y acota los grupos del SDK; la prioridad
    /// no fija núcleos ni garantiza fluidez. Los 256 MiB son un objetivo, no un cap.
    nonisolated private static func loadLocal(directory: URL, policy: ModelLoadingPolicy) async throws -> ModelContainer {
        try await LocalModelLoadAttempt<ModelContainer>.loadDetached(cancelPolicy: { policy.cancel() }) {
            try await ModelLoadingPolicy.withPolicy(policy) {
                try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
            }
        }
    }

    nonisolated private static func loadingMemoryFits(budget: Int) -> Bool {
        let memory = Memory.snapshot()
        // El mayor grupo del modelo elegido ocupa 378 MiB. Reservar 512 MiB
        // evita empezar el siguiente grupo pegado al presupuesto del intento.
        let reserve = 512 * 1_024 * 1_024
        return budget > reserve && memory.activeMemory <= budget - reserve
            && memory.cacheMemory <= budget - reserve - memory.activeMemory
    }

    var modelContainer: ModelContainer? { container }

    /// RAM física del dispositivo en GB.
    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Ventana de contexto de LFM2.5-8B configurada según la RAM de esta máquina.
    /// Los pesos MLX de 8 bits ocupan aproximadamente 8.4 GB; `maxKVSize` acota
    /// el crecimiento de la caché de contexto. Esta tabla es la
    /// FUENTE ÚNICA de `maxKVSize`: el modelo admite 128k y su KV-cache es ligero
    /// (arquitectura híbrida: 18 capas conv + solo 6 de atención GQA de 24).
    static var contextWindowTokens: Int {
        switch physicalMemoryGB {
        case 20...:      return 131072   // ≥24 GB: contexto COMPLETO de 128k.
        case 14.5..<20:  return 65536    // ≈16 GB: 64k.
        case 7.5..<14.5: return 32768    // ≈8–12 GB: 32k.
        case 5.5..<7.5:  return 8192     // ≈6 GB.
        default:         return 4096     // ≤4 GB.
        }
    }

    /// Etiqueta breve de la ventana de contexto, p. ej. «128k tokens de contexto».
    static var contextWindowLabel: String { "\(contextWindowTokens / 1024)k tokens de contexto" }

    static func recommendedParameters(maxTokens: Int) -> GenerateParameters {
        let gb = physicalMemoryGB
        let lowRAM = gb < 5.5            // ≤4 GB: cuantiza el KV y acota la generación.
        let maxKV = contextWindowTokens
        let kvBits: Int? = lowRAM ? 8 : nil
        let capped = lowRAM ? min(maxTokens, 1536) : maxTokens
        aiLog.info("Autoconfig LFM2.5 — RAM≈\(String(format: "%.1f", gb))GB, maxKV=\(maxKV), kvBits=\(kvBits ?? 0), maxTokens=\(capped)")
        // Parámetros OFICIALES de LiquidAI para LFM2.5 (no los de Qwen): temperature 0.2,
        // top_k 80, repetition_penalty 1.05. Más deterministas → tool calling más fiable.
        return GenerateParameters(
            maxTokens: capped,
            maxKVSize: maxKV,
            kvBits: kvBits,
            quantizedKVStart: kvBits == nil ? 0 : 512,
            temperature: 0.2,
            topP: 1.0,
            topK: 80,
            minP: 0.0,
            repetitionPenalty: 1.05,
            prefill: .init(stepSize: 512, chunking: .remainder)
        )
    }

    /// Genera una respuesta one-shot (sin historial ni herramientas) con el modelo
    /// ya cargado. Para sugerencias/clasificación. Devuelve nil si no está listo.
    ///
    /// Una sesión directa del LFM elegido recibe el prefijo vacío contrastado por
    /// LiquidSessionConfiguration; su plantilla no interpreta enable_thinking.
    /// La sesión con pensamiento conserva íntegra la entrada habitual del modelo.
    func complete(system: String, prompt: String, maxTokens: Int = 500,
                  enableThinking: Bool = true, observer: OneShotObserver? = nil) async -> String? {
        while embeddingSearchReservations > 0 || !conversationRounds.isEmpty {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        guard container != nil || isAvailable else { return nil }
        let identifier = UUID()
        oneShotRequests += 1
        defer {
            oneShotTasks.removeValue(forKey: identifier)
            cancelledOneShotRequests.remove(identifier)
            oneShotRequests -= 1
        }
        guard let container = await ensureReady(observer: observer) else { return nil }
        guard !Task.isCancelled else { return nil }
        let t0 = Date()
        let parameters = Self.recommendedParameters(maxTokens: maxTokens)
        let selectedModelID = Self.modelID
        let task = Task.detached { [self] () -> String? in
            do {
                let result: String? = try await LiquidSessionConfiguration.withSessionContainer(
                    for: container, modelID: selectedModelID, thinking: enableThinking, observer: observer
                ) { sessionContainer in
                    let session = ChatSession(
                        sessionContainer,
                        instructions: system,
                        generateParameters: parameters,
                        additionalContext: enableThinking ? nil : ["enable_thinking": false]
                    )
                    var output = ""
                    var cancelled = false
                    var rejectedToolCall = false
                    var receivedEvent = false
                    do {
                        for try await item in session.streamDetails(to: prompt, images: [], videos: []) {
                            if !receivedEvent {
                                receivedEvent = true
                                LiquidSessionConfiguration.observe(observer, at: .firstStreamEvent)
                            }
                            if let info = item.info {
                                LiquidSessionConfiguration.observe(observer, at: .completionInfo, completion: info)
                            }
                            // El primer evento confirma que el productor ya adquirió su caché.
                            // No se cancela este consumidor antes de alcanzar esa barrera.
                            cancelled = await MainActor.run {
                                if cancelledOneShotRequests.contains(identifier) {
                                    oneShotTasks[identifier]?.cancel()
                                    return true
                                }
                                return false
                            }
                            // Continúa hasta que next observe la cancelación y termine el
                            // stream; entonces synchronize espera el cierre del productor.
                            if cancelled { continue }
                            if item.rejectedToolCall != nil { rejectedToolCall = true }
                            if !rejectedToolCall, let chunk = item.chunk { output += chunk }
                        }
                    } catch {
                        await session.synchronize()
                        LiquidSessionConfiguration.observe(observer, at: .sessionSynchronized)
                        return nil
                    }
                    await session.synchronize()
                    LiquidSessionConfiguration.observe(observer, at: .sessionSynchronized)
                    return cancelled || rejectedToolCall ? nil : output
                }
                LiquidSessionConfiguration.observe(observer, at: .leaseReturned)
                return result
            } catch { return nil }
        }
        oneShotTasks[identifier] = task
        let out = await withTaskCancellationHandler(operation: { await task.value }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.oneShotTasks[identifier] != nil else { return }
                self.cancelledOneShotRequests.insert(identifier)
            }
        })
        guard !Task.isCancelled, !cancelledOneShotRequests.contains(identifier) else { return nil }
        let dt = Date().timeIntervalSince(t0)
        let cps = Int(Double(out?.count ?? 0) / max(dt, 0.1))
        AgentDiagnostics.shared.log("COMPLETE: \(out?.count ?? -1) chars en \(String(format: "%.1f", dt))s (~\(cps) chars/s, think=\(enableThinking))")
        return out
    }

    /// Libera el modelo de la RAM sin tocar la decisión de (des)activación. Lo usa el
    /// cambio de motor a Apple (recuperar memoria) — al volver a Liquid podrá cargarse.
    func unload() { unload(loadError: CancellationError()) }

    private func unload(loadError: any Error) {
        if loadAdmission.requestUnload(attempt: loadAttempt, reason: loadError,
                                       hasActiveInference: hasActiveInference) {
            unloadWhenIdle = true
            return
        }
        unloadWhenIdle = false
        container = nil
        Memory.clearCache()
        state = .notLoaded
    }

    /// Desactiva la IA local a petición del usuario («Descargar de la memoria»): la
    /// saca de la RAM y marca que NO debe autocargarse en ninguna sección hasta que
    /// el usuario la reactive con «Cargar modelo» (`ensureReady(userInitiated: true)`).
    func deactivate() {
        isDeactivated = true
        unload()
    }

    /// Borra los archivos descargados del modelo (libera espacio).
    func deleteDownload() {
        unload()
        try? FileManager.default.removeItem(at: Self.modelDirectory())
        isDownloaded = false
    }

    private func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "No se pudo descargar el modelo (red). Comprueba tu conexión e inténtalo de nuevo."
        }
        return "No se pudo preparar el modelo: \(error.localizedDescription)"
    }
}
