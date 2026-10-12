import SwiftUI
import SwiftData
import AppKit
import NaturalLanguage
import StacklumeCore
import StacklumePersistence
import StacklumeDesignSystem

/// Publicación curada desde la ficha; solo la apertura explícita envía el borrador a X.
struct XPostComposerView: View {
    let link: Bookmark
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft = XPostDraft()
    @State private var lastSavedDraft: XPostDraft?
    @State private var loadedLinkID: UUID?
    @State private var generating = false
    @State private var generation: Task<Void, Never>?
    @State private var generationID: UUID?
    @State private var status = "El borrador se conserva en este Mac."
    @State private var sourceText = ""
    @State private var showSource = false
    @State private var comparing = false
    @State private var authorResolution: XPostAuthorResolution?
    @State private var authorResolving = false
    @State private var authorLookup: Task<Void, Never>?
    @State private var authorLookupID: UUID?

    private var sourceURL: URL? {
        guard link.fileKind == nil, let url = StacklumeAutomationPolicy.openableStoredURL(link.url),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { return nil }
        return url
    }
    private var length: Int { XPostPolicy.weightedLength(draft.text) }
    private var canOpen: Bool { sourceURL != nil && XPostPolicy.intentURL(text: draft.text) != nil && !generating && !authorResolving }
    private var verifiedAuthor: XPostAuthorEvidence? {
        guard let resolution = authorResolution, case .verified(let evidence) = resolution,
              evidence.resourceURL == sourceURL?.absoluteString else { return nil }
        return evidence
    }
    private var configuredMention: String? { draft.mentionEnabled ? verifiedAuthor?.handle : nil }

    var body: some View {
        EditorScaffold(title: "Crear publicación para X", confirmTitle: "Abrir borrador en X",
                       canConfirm: canOpen, cancelTitle: "Cerrar", onCancel: { cancelGeneration(); cancelAuthorLookup(); dismiss() }, onConfirm: openInX) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.title).stacklumeFont(.headline).stacklumeLineLimit(2)
                        Text(link.url).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(2).textSelection(.enabled)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignSystem.Spacing.md) { anglePicker; languagePicker }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) { anglePicker; languagePicker }
                    }.disabled(generating)
                    TextField("¿Para quién? (opcional)", text: $draft.audience).textFieldStyle(.roundedBorder).disabled(generating)
                    toneControls
                    hashtagControls
                    authorControls
                    generationControls
                    Text(status).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        .accessibilityLabel("Estado: \(status)")
                    variantControls
                    if comparing { variantComparison }
                    if showSource {
                        Text(sourceText).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(draft.selectedVariant.map { "Editar: \($0.tone.title)" } ?? "Texto de la publicación")
                        .stacklumeFont(.subheadline.weight(.semibold))
                    TextEditor(text: Binding(get: { draft.text }, set: { draft.updateSelectedText($0) }))
                        .stacklumeFont(.body).scrollContentBackground(.hidden)
                        .padding(DesignSystem.Spacing.xs).frame(minHeight: 150, idealHeight: 190)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius).stroke(palette.border, lineWidth: 1))
                        .accessibilityLabel("Texto de la publicación")
                        .disabled(generating)
                    HStack {
                        Text("\(length)/280").monospacedDigit()
                            .foregroundStyle(length > 280 ? palette.textPrimary : palette.textSecondary)
                        if length > 280 { Text("Reduce \(length - 280) caracteres").stacklumeFont(.caption.weight(.semibold)) }
                        Spacer()
                        Button("Copiar", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft.text, forType: .string)
                            status = "Publicación copiada."
                        }.disabled(draft.text.isEmpty || generating)
                    }
                    Text("Revisa cada afirmación. Al abrir el borrador, podrás publicarlo desde X.")
                        .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .frame(minWidth: 420, idealWidth: 680, maxWidth: 800, minHeight: 560, idealHeight: 760, maxHeight: 900)
        .onAppear(perform: loadDraft)
        .onChange(of: link.id) { _, _ in loadDraft() }
        .onChange(of: link.url) { _, _ in
            cancelGeneration()
            cancelAuthorLookup()
            sourceText = ""
            showSource = false
            draft.suggestedHashtags = []
            draft.verifiedAuthor = nil
            status = "El enlace ha cambiado. Tu texto se conserva; vuelve a generar para consultar la nueva fuente."
            resolveAuthor()
        }
        .onChange(of: draft) { _, _ in persist() }
        .onDisappear { cancelGeneration(); cancelAuthorLookup() }
    }

    private var anglePicker: some View {
        Picker("Enfoque", selection: $draft.angle) {
            ForEach(["Descubrimiento", "Problema y solución", "Recomendación práctica"], id: \.self) { Text($0) }
        }
    }

    private var languagePicker: some View {
        Picker("Idioma", selection: $draft.language) {
            Text("Español").tag("es")
            Text("Inglés").tag("en")
        }
    }

    private var toneControls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Picker("Tono para generar", selection: $draft.tone) {
                ForEach(XPostTone.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(generating)
            Text(draft.tone.instruction).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
        }
    }

    private var hashtagControls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Picker("Hashtags", selection: $draft.hashtagMode) {
                ForEach(XPostHashtagMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(generating)
            if draft.hashtagMode == .manual {
                TextField("Hasta tres hashtags separados por espacios", text: $draft.manualHashtags)
                    .textFieldStyle(.roundedBorder).disabled(generating)
                let tags = XPostPolicy.normalizedHashtags(draft.manualHashtags)
                Text(tags.isEmpty ? "Escribe términos con letras, números o guion bajo." : "Se usarán: " + tags.prefix(3).map { "#" + $0 }.joined(separator: " "))
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            if !draft.suggestedHashtags.isEmpty {
                Text("Términos de la fuente: " + draft.suggestedHashtags.map { "#" + $0 }.joined(separator: " "))
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary).textSelection(.enabled)
            } else if draft.hashtagMode == .automatic {
                Text("Al generar se buscarán términos relevantes en la fuente.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            Text("Las sugerencias se basan en el contenido; su popularidad en X no se ha comprobado.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            if !draft.text.isEmpty {
                Button("Aplicar hashtags al texto actual", action: applyHashtags)
                    .disabled(generating || authorResolving || sourceURL == nil)
                    .themedHelp("Actualiza los hashtags añadidos por Stacklume y ajusta el texto al límite de X.")
            }
        }
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("IA local: \(LocalAIRunner.modelDisplayName)").stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) { generationButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) { generationButtons }
            }
            if !sourceText.isEmpty {
                Button(showSource ? "Ocultar fuente" : "Ver fuente") { showSource.toggle() }
            }
            if sourceURL == nil {
                Text("Elige un enlace web público para crear una publicación.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var authorControls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Toggle("Mencionar al autor al generar", isOn: Binding(get: { draft.mentionEnabled }, set: setMentionEnabled))
                .toggleStyle(.checkbox)
                .disabled(generating || authorResolving)
            if authorResolving {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Buscando una cuenta enlazada por el recurso…").stacklumeFont(.caption)
                }
                Button("Cancelar búsqueda") { cancelAuthorLookup(); authorResolution = .unavailable }
            } else if let author = verifiedAuthor {
                Text("Cuenta enlazada: @\(author.handle)").stacklumeFont(.subheadline.weight(.semibold)).textSelection(.enabled)
                if let accountURL = URL(string: author.profileURL) { Link("Revisar cuenta en X", destination: accountURL) }
                ForEach(Array(author.chain.enumerated()), id: \.offset) { index, source in
                    if let url = URL(string: source) {
                        Link("\(index == author.chain.count - 1 ? "Enlace comprobado" : "Procedencia"): \(source)", destination: url)
                            .stacklumeFont(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Comprueba que la cuenta siga correspondiendo al autor antes de publicar.")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                if !draft.text.isEmpty {
                    Button("Aplicar elección de mención a las variantes") { setMentionEnabled(draft.mentionEnabled) }
                        .disabled(generating)
                        .themedHelp("Añade o retira solo la mención gestionada por Stacklume. Conserva el texto editado.")
                }
            } else {
                Text(authorMessage).stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            if !authorResolving, sourceURL != nil {
                Button("Comprobar cuenta de nuevo", action: resolveAuthor).disabled(generating)
            }
        }
    }

    private var authorMessage: String {
        switch authorResolution {
        case .some(.ambiguous): "Hay varias cuentas posibles. No se añadirá una mención automática."
        case .some(.unavailable): "No se pudo comprobar la cuenta. No se añadirá una mención automática."
        default: "No se ha encontrado una cuenta de X enlazada por el autor. No se añadirá una mención automática."
        }
    }

    @ViewBuilder private var generationButtons: some View {
        if generating {
            ProgressView().controlSize(.small).accessibilityLabel("Generando variantes")
            Button("Cancelar generación") {
                cancelGeneration()
                status = "Generación cancelada. Las variantes y sus ediciones se conservan."
            }
        } else {
            let exists = draft.variants.contains { $0.tone == draft.tone }
            Button(exists ? "Regenerar \(draft.tone.title.lowercased())" : "Generar variante", systemImage: exists ? "arrow.clockwise" : "text.badge.plus") { generate(tones: [draft.tone]) }
                .buttonStyle(.bordered).disabled(sourceURL == nil || authorResolving)
            Button("Generar los cinco tonos") { generate(tones: XPostTone.allCases) }
                .buttonStyle(.bordered).disabled(sourceURL == nil || authorResolving)
                .themedHelp("Genera y revisa los tonos uno a uno con el mismo modelo. Guarda el conjunto cuando terminan los cinco; cancelar o un fallo conserva todas las versiones anteriores.")
        }
    }

    @ViewBuilder private var variantControls: some View {
        if !draft.variants.isEmpty {
            Picker("Variante activa", selection: Binding(get: { draft.selectedVariantID }, set: { id in
                if let id { draft.selectVariant(id) }
            })) {
                ForEach(draft.variants) { variant in
                    Text(variant.tone.title).tag(Optional(variant.id))
                }
            }.disabled(generating)
            if draft.variants.count > 1 {
                Toggle("Comparar variantes", isOn: $comparing).toggleStyle(.checkbox)
            }
        } else {
            Text("Genera un tono o escribe tu borrador. Las variantes se guardan con este enlace.")
                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
        }
    }

    private var variantComparison: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(draft.variants) { variant in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Text(variant.tone.title).stacklumeFont(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(XPostPolicy.weightedLength(variant.text))/280").stacklumeFont(.caption).monospacedDigit()
                    }
                    Text(variant.text).stacklumeFont(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignSystem.Spacing.sm) { variantActions(variant) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) { variantActions(variant) }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
            }
        }
    }

    @ViewBuilder private func variantActions(_ variant: XPostVariant) -> some View {
        Button(draft.selectedVariantID == variant.id ? "Seleccionada" : "Seleccionar y editar") { draft.selectVariant(variant.id) }
            .disabled(generating || draft.selectedVariantID == variant.id)
        Button("Regenerar", systemImage: "arrow.clockwise") { generate(tones: [variant.tone]) }
            .disabled(generating || authorResolving || sourceURL == nil)
            .accessibilityLabel("Regenerar variante \(variant.tone.title)")
    }

    private func loadDraft() {
        guard loadedLinkID != link.id else { return }
        cancelGeneration()
        cancelAuthorLookup()
        persist()
        draft = XPostDraftStore.load(link.id) ?? XPostDraft(language: AppSettingsStore.current(in: context).language.rawValue)
        lastSavedDraft = draft
        loadedLinkID = link.id
        sourceText = ""
        showSource = false
        comparing = false
        status = "El borrador y sus variantes se conservan en este Mac."
        resolveAuthor()
    }

    private func persist() {
        guard let loadedLinkID, draft != lastSavedDraft else { return }
        do {
            try XPostDraftStore.save(draft, id: loadedLinkID)
            lastSavedDraft = draft
        }
        catch { status = "No se pudo guardar el borrador: \(error.localizedDescription)" }
    }

    private func resolveAuthor() {
        guard !generating, let resource = sourceURL, let linkID = loadedLinkID else { return }
        cancelAuthorLookup()
        authorResolution = nil
        authorResolving = true
        let identifier = UUID()
        authorLookupID = identifier
        authorLookup = Task { @MainActor in
            defer { if authorLookupID == identifier { authorResolving = false; authorLookupID = nil; authorLookup = nil } }
            do {
                let result = try await XPostAuthorResolver.resolve(resource)
                try Task.checkCancellation()
                guard authorLookupID == identifier, loadedLinkID == linkID, sourceURL == resource else { return }
                authorResolution = result
                var candidate = draft
                if case .verified(let evidence) = result { candidate.verifiedAuthor = evidence }
                else { candidate.verifiedAuthor = nil }
                try XPostDraftStore.save(candidate, id: linkID)
                lastSavedDraft = candidate
                draft = candidate
            } catch {
                guard !Task.isCancelled, authorLookupID == identifier else { return }
                authorResolution = .unavailable
                status = "No se pudo guardar la comprobación del autor. Tu texto se conserva."
            }
        }
    }

    private func cancelAuthorLookup() {
        authorLookupID = nil
        authorLookup?.cancel()
        authorLookup = nil
        authorResolving = false
    }

    private func setMentionEnabled(_ enabled: Bool) {
        guard !generating, !authorResolving, let source = sourceURL, let id = loadedLinkID else { return }
        var candidate = draft
        candidate.mentionEnabled = enabled
        candidate.verifiedAuthor = verifiedAuthor
        if !enabled || verifiedAuthor != nil { candidate.applyMention(enabled ? verifiedAuthor?.handle : nil, source: source) }
        do {
            try XPostDraftStore.save(candidate, id: id)
            lastSavedDraft = candidate
            draft = candidate
            status = "Elección de mención guardada. Revisa las variantes y ajusta cualquier texto que supere 280 caracteres."
        } catch { status = "No se pudo actualizar la mención: \(error.localizedDescription) Tu texto se conserva." }
    }

    private func applyHashtags() {
        guard let source = sourceURL else { return }
        let previous = draft.selectedVariant?.appliedHashtags ?? []
        let composed = XPostPolicy.applyingHashtags(to: draft.text, source: source,
                                                  hashtags: draft.configuredHashtags, previousApplied: previous,
                                                  mention: configuredMention, previousMention: draft.selectedVariant?.appliedMention)
        draft.updateSelectedText(composed.text)
        if let index = draft.variants.firstIndex(where: { $0.id == draft.selectedVariantID }) {
            draft.variants[index].appliedHashtags = composed.appliedHashtags
            draft.variants[index].appliedMention = composed.appliedMention
        }
        status = "Hashtags aplicados. Revisa el texto ajustado al límite de X."
    }

    private func generate(tones: [XPostTone]) {
        guard let url = sourceURL, !authorResolving, !generating else { return }
        generating = true
        status = "Consultando la fuente…"
        let angle = draft.angle, audience = String(draft.audience.prefix(500)), language = draft.language
        let requestedLinkID = link.id, title = link.title
        let requestedDraft = draft
        let storedSource = link.offlineText ?? link.summary ?? title
        let sourceTags = link.tags.map(\.name)
        let mode = draft.hashtagMode, manual = draft.manualHashtags
        let mention = configuredMention, author = verifiedAuthor
        let identifier = UUID()
        generationID = identifier
        generation = Task { @MainActor in
            defer { if generationID == identifier { generating = false; generationID = nil; generation = nil } }
            let fetched = await AIBatchEnricher.pageContentExcerpt(for: url.absoluteString)
            guard !Task.isCancelled, generationID == identifier, loadedLinkID == requestedLinkID, link.id == requestedLinkID else { return }
            let source = fetched ?? storedSource
            let sourceWasTruncated = source.count >= 3_500
            sourceText = String(ProseText.clean(source).prefix(3_500))
            let suggestions = XPostPolicy.suggestedHashtags(title: title, source: sourceText, tags: sourceTags)
            let hashtags: [String] = switch mode {
            case .none: []
            case .automatic: Array(suggestions.prefix(XPostPolicy.maximumAppliedHashtags))
            case .manual: XPostPolicy.normalizedHashtags(manual, maximum: XPostPolicy.maximumAppliedHashtags)
            }
            let consultedSource = sourceText
            let bodyBudget = XPostPolicy.limit - XPostPolicy.weightedLength(XPostPolicy.composed("", source: url, hashtags: hashtags, mention: mention)) - 2
            var workflow = XPostAuditedBatchWorkflow()
            var diagnostics: [XPostBatchDiagnostic] = []
            var phase = XPostBatchDiagnostic.Phase.generation
            var lastOutput = ""
            var pending: [XPostCopyFieldIssue] = []
            do {
                let context = try XPostCopyPolicy.generationContext(source: consultedSource, tone: .calm, sourceWasTruncated: sourceWasTruncated)
                // Mismo modelo que el asistente y el enriquecido actuales. El campo
                // aiProvider del core compartido es legado y no configura la app Mac.
                let runner = LocalAIRunner.shared
                guard !runner.isDeactivated, runner.isAvailable else { throw UnifiedAIError.liquidNotLoaded }
                // Pulsar Generar es un reintento explícito tras una carga fallida.
                if runner.modelContainer == nil {
                    status = "Cargando el modelo local…"
                    guard await runner.ensureReady(userInitiated: true) != nil else {
                        if case .failed(let message) = runner.state { throw GenerationError.modelLoading(message) }
                        throw UnifiedAIError.liquidNotLoaded
                    }
                }
                try Task.checkCancellation()
                var generationDraft = requestedDraft
                generationDraft.verifiedAuthor = author
                var batch = XPostGenerationBatch(draft: generationDraft, tones: tones, suggestedHashtags: suggestions)
                var previousTexts = requestedDraft.variants.filter { !tones.contains($0.tone) }.map(\.text)
                for (position, tone) in tones.enumerated() {
                    workflow = XPostAuditedBatchWorkflow()
                    pending = []
                    phase = .generation
                    let currentTones = [tone]
                    var rejected: XPostCopyBatch?
                    try workflow.beginGeneration()
                    var request = XPostGroupedCopyPolicy.prompt(context: context, tones: currentTones, title: title, language: language,
                                                               angle: angle, audience: audience, budget: bodyBudget, previousTexts: previousTexts)
                    status = "Generando \(tone.title.lowercased()) · \(position + 1)/\(tones.count)…"
                    while true {
                        guard generationID == identifier, loadedLinkID == requestedLinkID, link.id == requestedLinkID else { return }
                        lastOutput = ""
                        guard let output = await LocalAIRunner.shared.complete(system: request.system, prompt: request.user, maxTokens: 4096, enableThinking: true) else { throw UnifiedAIError.liquidFailed }
                        lastOutput = output
                        try Task.checkCancellation()
                        guard generationID == identifier, loadedLinkID == requestedLinkID, link.id == requestedLinkID else { return }
                        let copies: XPostCopyBatch
                        do {
                            copies = try XPostGroupedCopyPolicy.extract(output, tones: currentTones, context: context, repairing: rejected, issues: pending)
                        } catch let error as XPostCopyPolicy.CopyError where error == .malformed || error == .incomplete {
                            diagnostics.append(XPostBatchDiagnostic(call: workflow.calls, phase: phase, raw: output))
                            Self.recordCopyDiagnostics(diagnostics)
                            try workflow.beginRepair()
                            phase = .repair
                            status = "Corrigiendo el formato de la publicación…"
                            request = XPostGroupedCopyPolicy.prompt(context: context, tones: currentTones, title: title, language: language,
                                                                   angle: angle, audience: audience, budget: bodyBudget, previousTexts: previousTexts,
                                                                   repairing: rejected, issues: pending, repairingFormat: true)
                            continue
                        }
                        workflow.stage(copies)
                        var assessments: [XPostTone: XPostLanguageAssessment] = [:]
                        var fieldAssessments: [XPostTone: [XPostCopyField: XPostLanguageAssessment]] = [:]
                        var spelling: [XPostTone: [String]] = [:]
                        for (tone, copy) in copies.copies {
                            assessments[tone] = Self.languageAssessment(copy, requested: language)
                            fieldAssessments[tone] = [.gancho: Self.languageAssessment(copy.gancho, requested: language),
                                                      .utilidad: Self.languageAssessment(copy.utilidad, requested: language)]
                            spelling[tone] = Self.spellingIssues(copy.text, language: language)
                        }
                        pending = XPostGroupedCopyPolicy.lexicalIssues(copies, source: consultedSource, language: language, budget: bodyBudget,
                                                                      assessments: assessments, fieldAssessments: fieldAssessments,
                                                                      previousTexts: previousTexts)
                        diagnostics.append(XPostBatchDiagnostic(call: workflow.calls, phase: phase, raw: output, candidate: copies, issues: pending, fieldAssessments: fieldAssessments))
                        if pending.isEmpty {
                            try workflow.markLexicallyValid(revision: copies.revision)
                            phase = .audit
                            var auditAttempts = 0
                            while true {
                                try workflow.beginAudit()
                                auditAttempts += 1
                                status = auditAttempts == 1 ? "Revisando hechos, traducción y coherencia…" : "Corrigiendo el formato de la revisión…"
                                let auditRequest = XPostSemanticAuditPolicy.prompt(batch: copies, language: language, repairingFormat: auditAttempts > 1, spellingWarnings: spelling)
                                lastOutput = ""
                                guard let auditOutput = await LocalAIRunner.shared.complete(system: auditRequest.system, prompt: auditRequest.user, maxTokens: 4096, enableThinking: true) else { throw UnifiedAIError.liquidFailed }
                                lastOutput = auditOutput
                                try Task.checkCancellation()
                                guard generationID == identifier, loadedLinkID == requestedLinkID, link.id == requestedLinkID else { return }
                                do {
                                    let audit = try XPostSemanticAuditPolicy.extract(auditOutput, batch: copies)
                                    try workflow.receive(audit)
                                    pending = audit.issues
                                    diagnostics.append(XPostBatchDiagnostic(call: workflow.calls, phase: phase, raw: auditOutput, candidate: copies, issues: pending))
                                    break
                                } catch let error as XPostSemanticAuditPolicy.AuditError where auditAttempts < 3 && (error == .malformed || error == .invalidProvenance) {
                                    diagnostics.append(XPostBatchDiagnostic(call: workflow.calls, phase: phase, raw: auditOutput, candidate: copies,
                                                                           invalidProvenance: error == .invalidProvenance))
                                    Self.recordCopyDiagnostics(diagnostics)
                                }
                            }
                            if pending.isEmpty {
                                let approved = try workflow.completedBatch()
                                for tone in currentTones {
                                    guard let copy = approved.copies[tone] else { throw XPostCopyPolicy.CopyError.malformed }
                                    let composed = XPostPolicy.composition(copy.text, source: url, hashtags: hashtags, mention: mention)
                                    try batch.stage(tone: tone, text: composed.text, hashtags: composed.appliedHashtags, mention: composed.appliedMention)
                                    previousTexts.append(copy.text)
                                }
                                break
                            }
                        }
                        Self.recordCopyDiagnostics(diagnostics)
                        try workflow.beginRepair()
                        rejected = copies
                        phase = .repair
                        status = "Corrigiendo los campos que necesitan revisión…"
                        request = XPostGroupedCopyPolicy.prompt(context: context, tones: currentTones, title: title, language: language,
                                                               angle: angle, audience: audience, budget: bodyBudget, previousTexts: previousTexts,
                                                               repairing: copies, issues: pending)
                    }
                }
                guard generationID == identifier, loadedLinkID == requestedLinkID, link.id == requestedLinkID else { return }
                guard draft == requestedDraft else { throw XPostSemanticAuditPolicy.AuditError.staleRevision }
                let candidate = try batch.completedDraft()
                try XPostDraftStore.save(candidate, id: requestedLinkID)
                lastSavedDraft = candidate
                draft = candidate
                status = fetched == nil ? "Variantes guardadas con información local. Revisa los hechos en la fuente." : "Variantes guardadas y basadas en la fuente consultada."
            } catch {
                guard !Task.isCancelled, generationID == identifier, loadedLinkID == requestedLinkID, link.id == requestedLinkID else { return }
                diagnostics.append(XPostBatchDiagnostic(call: workflow.calls, phase: phase, raw: lastOutput, candidate: workflow.candidate,
                                                       invalidProvenance: (error as? XPostSemanticAuditPolicy.AuditError) == .invalidProvenance))
                Self.recordCopyDiagnostics(diagnostics)
                let unrecognized = Array(Set(pending.filter { $0.reason == .ortografia }.flatMap(\.words))).sorted()
                let detail = (error as? XPostSemanticAuditPolicy.AuditError) == .budget && !unrecognized.isEmpty
                    ? "El corrector no reconoce: " + unrecognized.prefix(6).joined(separator: ", ") + "."
                    : error.localizedDescription
                status = "No se pudo generar: \(detail) Tu texto se conserva."
            }
        }
    }

    private enum GenerationError: LocalizedError {
        case modelLoading(String)
        var errorDescription: String? {
            switch self { case .modelLoading(let message): message }
        }
    }

    private static func recordCopyDiagnostics(_ entries: [XPostBatchDiagnostic]) {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(Array(entries.suffix(7))), data.count <= 8_000 else { return }
        try? PrivateFileIO.write(data, to: root.appendingPathComponent("Stacklume/Diagnostics/XPostLastFailure.json"))
    }

    private static func languageAssessment(_ copy: XPostGeneratedCopy, requested: String) -> XPostLanguageAssessment {
        var combined = XPostLanguageAssessment(code: nil, confidence: 0, requestedConfidence: 0)
        for text in [copy.gancho, copy.utilidad, copy.text] {
            let assessment = languageAssessment(text, requested: requested)
            if assessment.code != requested, assessment.confidence >= 0.8, assessment.requestedConfidence < 0.15 { return assessment }
            combined = assessment
        }
        return combined
    }

    private static func languageAssessment(_ text: String, requested: String) -> XPostLanguageAssessment {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10)
        let code = recognizer.dominantLanguage
        return XPostLanguageAssessment(code: code?.rawValue, confidence: code.flatMap { hypotheses[$0] } ?? 0,
                                       requestedConfidence: hypotheses[NLLanguage(rawValue: requested)] ?? 0)
    }

    @MainActor private static func spellingIssues(_ text: String, language: String) -> [String] {
        let checker = NSSpellChecker.shared
        guard let dictionary = checker.availableLanguages.first(where: { $0 == language || $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-") }) else { return [] }
        let value = text as NSString
        var offset = 0, issues: [String] = []
        for _ in 0..<16 {
            let range = checker.checkSpelling(of: text, startingAt: offset, language: dictionary, wrap: false,
                                             inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, NSMaxRange(range) <= value.length, range.length > 0 else { break }
            issues.append(value.substring(with: range))
            offset = NSMaxRange(range)
        }
        return issues
    }

    private func cancelGeneration() {
        generationID = nil
        generation?.cancel()
        generation = nil
        generating = false
    }

    private func openInX() {
        guard canOpen, let url = XPostPolicy.intentURL(text: draft.text) else { return }
        persist()
        XWebHolder.shared.openComposer(url)
        NotificationCenter.default.post(name: .stacklumeGoToSection, object: "x")
        dismiss()
    }
}
