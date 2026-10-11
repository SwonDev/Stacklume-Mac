import SwiftUI
import SwiftData
import Charts
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Estadísticas e insights de la biblioteca: totales, distribución por colección,
/// ritmo de guardado, racha y dominios principales. Todo se calcula en local a
/// partir de los marcadores activos. En el iPhone es un destino propio (al que se
/// llega desde Ajustes); en Mac es una sección del sidebar con la misma intención.
struct StatsView: View {
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Query private var allLinks: [Bookmark]
    @Query(sort: \BookmarkCategory.order) private var categories: [BookmarkCategory]

    /// Lanzador de IA local (observado) para mostrar la tarjeta de insights solo si está lista.
    @State private var aiRunner = LocalAIRunner.shared
    /// Insight cacheado (se regenera a demanda; sobrevive entre aperturas).
    @AppStorage("stacklume.libraryInsight") private var cachedInsight = ""
    @State private var generatingInsight = false
    /// Digest semanal cacheado, con el formato «AAAA-Www|||texto» para invalidarlo al cambiar
    /// de semana ISO (cada lunes vuelve a estar disponible «Generar»).
    @AppStorage("stacklume.weeklyDigest") private var cachedDigestRaw = ""
    @State private var generatingDigest = false
    /// Recomendaciones «Para ti» (enlace recomendado + la semilla que lo motivó). Se calculan
    /// fuera del render (en `.task`) para no recomputar vectores/relaciones en cada repintado.
    @State private var recommendations: [(rec: Bookmark, seed: Bookmark)] = []
    /// Instantánea estable del lote: las fechas se mutan durante el repaso, por lo que no debe
    /// reconstruirse desde `dueForReview` en cada repintado de la hoja.
    @State private var reviewSessionIDs: [Bookmark.ID] = []
    @State private var showReviewSession = false

    private var links: [Bookmark] { allLinks.filter { $0.deletedAt == nil } }

    /// Recuerdos: enlaces guardados un día como hoy (mismo mes y día) en años anteriores.
    /// De más reciente a más antiguo, máx. 5. Vacío fuera de aniversarios (la tarjeta no aparece).
    private var onThisDay: [Bookmark] {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now), d = cal.component(.day, from: now)
        let y = cal.component(.year, from: now)
        return links.filter {
            cal.component(.month, from: $0.createdAt) == m
                && cal.component(.day, from: $0.createdAt) == d
                && cal.component(.year, from: $0.createdAt) < y
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// «hace 1 año» / «hace N años» a partir de la fecha de guardado.
    private func yearsAgoLabel(_ date: Date) -> String {
        let years = max(1, Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 1)
        return years == 1 ? "hace 1 año" : "hace \(years) años"
    }

    var body: some View {
        Group {
            if links.isEmpty {
                EmptyStateView(icon: "chart.bar.xaxis", title: "Sin datos todavía",
                               message: "Guarda algunos enlaces y aquí verás tus estadísticas.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                        // 1) Vistazo: las cifras clave de la biblioteca.
                        statsSection("General") { summaryCards }

                        // 2) Tu actividad: IA «segundo cerebro» + redescubrimiento. Solo si hay
                        //    algo que mostrar (evita una cabecera huérfana).
                        if hasActivityCards {
                            statsSection("Tu actividad") {
                                cardGrid(minimum: 360) {
                                    reviewCard
                                    weeklyDigestCard
                                    forYouCard
                                    insightsCard
                                    onThisDayCard
                                }
                            }
                        }

                        // 3) Lectura: progreso y racha.
                        statsSection("Lectura") { progressAndStreakRow }

                        // 4) Distribución: cómo se reparte la biblioteca.
                        statsSection("Distribución") {
                            cardGrid(minimum: 320) {
                                collectionChartCard
                                monthlyChartCard
                                contentTypeCard
                                topDomainsCard
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
                .background(WindowBackground())
            }
        }
        .navigationTitle("Estadísticas")
        // Recalcula «Para ti» al abrir y cuando cambia el nº de enlaces (no en cada repintado).
        .task(id: links.count) { recommendations = computeRecommendations() }
        .sheet(isPresented: $showReviewSession) {
            ReviewSessionView(linkIDs: reviewSessionIDs)
                .themedSheet(palette)
        }
    }

    // MARK: - Estructura (secciones y rejilla)

    /// Una sección del dashboard: cabecera + contenido, con separación clara entre secciones.
    @ViewBuilder
    private func statsSection<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .stacklumeFont(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            content()
        }
    }

    /// Rejilla adaptativa para las tarjetas de una sección: tantas columnas como quepan con el
    /// ancho mínimo dado, alineadas arriba. Las tarjetas vacías (sin datos) no ocupan hueco.
    @ViewBuilder
    private func cardGrid<Content: View>(minimum: CGFloat,
                                         @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: DesignSystem.Spacing.md)],
                  alignment: .leading, spacing: DesignSystem.Spacing.md) {
            content()
        }
    }

    /// ¿Hay alguna tarjeta que mostrar en «Tu actividad»? Evita la cabecera huérfana.
    private var hasActivityCards: Bool {
        !savedThisWeek.isEmpty
            || !recommendations.isEmpty
            || (aiRunner.isDownloaded && !aiRunner.isDeactivated)
            || !onThisDay.isEmpty
            || !dueForReview.isEmpty
    }

    // MARK: - Para repasar (resurfacing / segundo cerebro)

    /// Enlaces cuyo REPASO toca ya (`reviewAt` en el pasado), del más atrasado al más reciente.
    private var dueForReview: [Bookmark] {
        let now = Date()
        return links.filter { link in
            guard let date = link.reviewAt else { return false }
            return date <= now
        }.sorted { ($0.reviewAt ?? .distantPast) < ($1.reviewAt ?? .distantPast) }
    }

    @ViewBuilder
    private var reviewCard: some View {
        let items = Array(dueForReview.prefix(4))
        if !items.isEmpty {
            chartCard("Para repasar", systemImage: "arrow.triangle.2.circlepath") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(dueForReview.count) enlace\(dueForReview.count == 1 ? " vuelve" : "s vuelven") hoy a tu atención.")
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                    ForEach(items) { link in
                        HStack(spacing: 8) {
                            Button {
                                if let u = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(u) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: link.platform.sfSymbol)
                                        .font(.caption)
                                        .foregroundStyle(palette.accent)
                                        .frame(width: 22, height: 22)
                                        .background(palette.accent.opacity(0.14),
                                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(link.title.isEmpty ? link.url.urlHost : link.title)
                                            .stacklumeFont(.callout).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                                        Text(link.url.urlHost)
                                            .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .themedHelp("Abrir «\(link.title.isEmpty ? link.url : link.title)»")

                            Button {
                                BookmarkActions.setReviewDate(nil, for: link, in: context)
                            } label: {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .themedHelp("Marcar como repasado")
                            .accessibilityLabel("Marcar como repasado")
                        }
                    }
                    HStack {
                        if dueForReview.count > items.count {
                            Text("Y \(dueForReview.count - items.count) más")
                                .stacklumeFont(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                        Spacer()
                        Button("Iniciar repaso", systemImage: "play.fill") {
                            reviewSessionIDs = dueForReview.map(\.id)
                            showReviewSession = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .themedHelp("Repasar todos los enlaces pendientes")
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Tarjetas resumen

    private var summaryCards: some View {
        // 2×2 fijo: un bloque limpio y equilibrado para las 4 cifras clave (la rejilla
        // adaptativa dejaba un «3+1» descompensado en el ancho típico del panel).
        LazyVGrid(columns: [GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
                            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)],
                  spacing: DesignSystem.Spacing.sm) {
            // Tints de tono MEDIO: contrastan bien tanto en temas oscuros (sobre navy)
            // como claros (sobre superficie casi blanca). Se evitan tonos muy claros
            // (ámbar/verde menta) que en claro quedaban lavados sobre blanco.
            statCard("Total", value: links.count, icon: "link", tint: palette.accent)
            statCard("Sin leer", value: links.filter { !$0.isRead }.count,
                     icon: "circle.badge.exclamationmark", tint: Color(hex: "#3B82F6"))
            statCard("Favoritos", value: links.filter(\.isFavorite).count,
                     icon: "star.fill", tint: Color(hex: "#D99A00"))
            statCard("Este mes", value: savedThisMonth, icon: "calendar", tint: Color(hex: "#17A673"))
        }
    }

    private func statCard(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
            }
            Text("\(value)")
                .stacklumeFont(.title.weight(.bold))
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.numericText())
            Text(title)
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Resumen de la biblioteca con IA (on-device)

    @ViewBuilder
    private var insightsCard: some View {
        // Solo si la IA local está disponible (no se muestra un botón muerto).
        if aiRunner.isDownloaded && !aiRunner.isDeactivated {
            chartCard("Resumen con IA", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 10) {
                    if !cachedInsight.isEmpty {
                        Text(cachedInsight)
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !generatingInsight {
                        Text("Genera, en local, un resumen de tus intereses y temas a partir de tu biblioteca.")
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    HStack(spacing: 8) {
                        if generatingInsight {
                            ProgressView().controlSize(.small)
                            Text("Analizando tu biblioteca…")
                                .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                        } else {
                            Button(cachedInsight.isEmpty ? "Generar con IA" : "Regenerar",
                                   systemImage: "sparkles") { generateInsight() }
                                .buttonStyle(.borderless)
                                .tint(palette.accent)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func generateInsight() {
        guard !generatingInsight else { return }
        generatingInsight = true
        let language = AppSettingsStore.current(in: context).language.rawValue
        Task {
            let text = await LibraryInsights.generate(in: context, language: language)
            await MainActor.run {
                if let text { cachedInsight = text }
                generatingInsight = false
            }
        }
    }

    // MARK: - Resumen de la semana (digest)

    /// Enlaces guardados en los últimos 7 días, de más reciente a más antiguo.
    private var savedThisWeek: [Bookmark] {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return links.filter { $0.createdAt >= since }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Temas dominantes de la semana (colección o, si no hay, tipo de contenido) con recuento,
    /// para las «chips» deterministas que se muestran SIN depender de la IA.
    private var weekThemes: [(name: String, count: Int)] {
        let week = savedThisWeek
        let cats = week.compactMap { $0.category?.name }
        let source = cats.count >= 2 ? cats : week.map { $0.contentType.displayName }
        return Dictionary(grouping: source, by: { $0 }).mapValues(\.count)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4).map { (name: $0.key, count: $0.value) }
    }

    /// Sello de semana ISO «AAAA-Www» (cambia cada lunes), para invalidar el digest cacheado.
    private var weekStamp: String {
        let c = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// Texto del digest SOLO si es de la semana actual (si la semana cambió, se considera vacío).
    private var cachedDigest: String {
        let parts = cachedDigestRaw.components(separatedBy: "|||")
        guard parts.count == 2, parts[0] == weekStamp else { return "" }
        return parts[1]
    }

    @ViewBuilder
    private var weeklyDigestCard: some View {
        let week = savedThisWeek
        // Solo merece la pena si guardaste algo esta semana.
        if !week.isEmpty {
            chartCard("Resumen de la semana", systemImage: "calendar.badge.clock") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Esta semana guardaste **\(week.count)** \(week.count == 1 ? "enlace" : "enlaces").")
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textPrimary)

                    if !weekThemes.isEmpty {
                        // Chips de temas (deterministas, siempre disponibles sin IA).
                        FlowChips(items: weekThemes.map { "\($0.name) · \($0.count)" }, tint: palette.accent)
                    }

                    if !cachedDigest.isEmpty {
                        Text(cachedDigest)
                            .stacklumeFont(.callout)
                            .foregroundStyle(palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // El resumen con IA solo si está disponible y hay material suficiente.
                    if aiRunner.isDownloaded && !aiRunner.isDeactivated && week.count >= 3 {
                        HStack(spacing: 8) {
                            if generatingDigest {
                                ProgressView().controlSize(.small)
                                Text("Resumiendo tu semana…")
                                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
                            } else {
                                Button(cachedDigest.isEmpty ? "Generar resumen con IA" : "Regenerar",
                                       systemImage: "sparkles") { generateDigest() }
                                    .buttonStyle(.borderless)
                                    .tint(palette.accent)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func generateDigest() {
        guard !generatingDigest else { return }
        generatingDigest = true
        let language = AppSettingsStore.current(in: context).language.rawValue
        let stamp = weekStamp
        Task {
            let text = await LibraryInsights.digest(in: context, language: language, days: 7)
            await MainActor.run {
                if let text { cachedDigestRaw = "\(stamp)|||\(text)" }
                generatingDigest = false
            }
        }
    }

    // MARK: - Para ti (recomendaciones «porque guardaste X»)

    /// Calcula recomendaciones: parte de SEMILLAS con las que el usuario se implicó (favoritos
    /// y, si no hay, leídos recientes) y, vía la relación REAL de [[SemanticSearch]] (etiqueta/
    /// dominio/categoría compartidos + coseno), sugiere enlaces aún SIN LEER. Una por semilla
    /// para dar variedad, hasta 4. Determinista incluso sin embeddings (las señales duras bastan).
    private func computeRecommendations() -> [(rec: Bookmark, seed: Bookmark)] {
        let lang = AppSettingsStore.current(in: context).language.rawValue
        let active = links.filter { !$0.isArchived }
        let favorites = active.filter(\.isFavorite).sorted { $0.updatedAt > $1.updatedAt }
        let seeds = (favorites.isEmpty
                     ? active.filter(\.isRead).sorted { $0.updatedAt > $1.updatedAt }
                     : favorites).prefix(8)
        var result: [(rec: Bookmark, seed: Bookmark)] = []
        var used = Set<UUID>()
        for seed in seeds {
            let related = SemanticSearch.related(to: seed, in: active, language: lang, limit: 8)
            if let pick = related.first(where: { !$0.isRead && !$0.isFavorite
                && $0.id != seed.id && !used.contains($0.id) }) {
                result.append((rec: pick, seed: seed))
                used.insert(pick.id)
                if result.count >= 4 { break }
            }
        }
        return result
    }

    @ViewBuilder
    private var forYouCard: some View {
        if !recommendations.isEmpty {
            chartCard("Para ti", systemImage: "sparkles.rectangle.stack") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recommendations, id: \.rec.id) { item in
                        Button {
                            if let u = StacklumeAutomationPolicy.openableStoredURL(item.rec.url) { openURL(u) }
                        } label: {
                            HStack(spacing: 8) {
                                SecureRemoteImage(candidates: [item.rec.faviconURL]) {
                                    Image(systemName: item.rec.platform.sfSymbol)
                                        .font(.caption).foregroundStyle(palette.accent)
                                }
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.rec.title.isEmpty ? item.rec.url.urlHost : item.rec.title)
                                        .stacklumeFont(.callout).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                                    Text("Porque guardaste «\(item.seed.title.isEmpty ? item.seed.url.urlHost : item.seed.title)»")
                                        .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2).foregroundStyle(palette.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themedHelp("Abrir «\(item.rec.title.isEmpty ? item.rec.url : item.rec.title)»")
                    }
                }
            }
        }
    }

    // MARK: - Un día como hoy (recuerdos)

    @ViewBuilder
    private var onThisDayCard: some View {
        let memories = Array(onThisDay.prefix(5))
        if !memories.isEmpty {
            chartCard("Un día como hoy", systemImage: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(memories) { link in
                        Button {
                            if let u = StacklumeAutomationPolicy.openableStoredURL(link.url) { openURL(u) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: link.platform.sfSymbol)
                                    .font(.caption)
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 22, height: 22)
                                    .background(palette.accent.opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(link.title.isEmpty ? link.url.urlHost : link.title)
                                        .stacklumeFont(.callout).foregroundStyle(palette.textPrimary).stacklumeLineLimit(1)
                                    Text("\(link.url.urlHost) · \(yearsAgoLabel(link.createdAt))")
                                        .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2).foregroundStyle(palette.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themedHelp("Abrir «\(link.title.isEmpty ? link.url : link.title)»")
                    }
                }
            }
        }
    }

    // MARK: - Progreso de lectura + racha

    private var progressAndStreakRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            readingProgressCard
            streakCard
        }
    }

    private var readingProgressCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Lectura", systemImage: "book.fill")
                .stacklumeFont(.subheadline.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .stroke(palette.accent.opacity(0.16), lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: readProgress)
                        .stroke(palette.accent.gradient,
                                style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(readProgress * 100))%")
                            .stacklumeFont(.title3.weight(.bold))
                            .foregroundStyle(palette.textPrimary)
                            .contentTransition(.numericText())
                        Text("leído")
                            .stacklumeFont(.caption2)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(width: 96, height: 96)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Racha", systemImage: "flame.fill")
                .stacklumeFont(.subheadline.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: "#F97316").gradient)
                Text("\(savingStreak)")
                    .scaledFont(40, weight: .bold)
                    .foregroundStyle(palette.textPrimary)
                    .contentTransition(.numericText())
            }
            if streakAtRisk {
                Text("¡Guarda un enlace hoy para mantenerla!")
                    .stacklumeFont(.caption2.weight(.medium))
                    .foregroundStyle(palette.readableForeground(Color(hex: "#F97316"), on: palette.surface))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(savingStreak == 1 ? "día seguido guardando" : "días seguidos guardando")
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Tipos de contenido

    private var contentTypeCard: some View {
        chartCard("Por tipo de contenido", systemImage: "square.grid.2x2.fill") {
            VStack(spacing: 10) {
                ForEach(contentTypeStats) { stat in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(stat.name)
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textPrimary)
                            .stacklumeLineLimit(1)
                            .frame(width: 92, alignment: .leading)
                        GeometryReader { geo in
                            let ratio = maxContentTypeCount > 0 ? CGFloat(stat.count) / CGFloat(maxContentTypeCount) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(stat.color.opacity(0.16))
                                Capsule().fill(stat.color.gradient)
                                    .frame(width: max(14, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 14)
                        Text("\(stat.count)")
                            .stacklumeFont(.caption.weight(.semibold))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Distribución por colección (donut)

    private var collectionChartCard: some View {
        chartCard("Por colección", systemImage: "folder.fill") {
            if collectionStats.isEmpty {
                emptyHint("Aún no has clasificado enlaces en colecciones.")
            } else {
                HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                    Chart(collectionStats) { stat in
                        SectorMark(angle: .value("Enlaces", stat.count),
                                   innerRadius: .ratio(0.62),
                                   angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(stat.color)
                    }
                    .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(collectionStats) { stat in
                            HStack(spacing: 8) {
                                Circle().fill(stat.color).frame(width: 9, height: 9)
                                Text(stat.name)
                                    .stacklumeFont(.caption)
                                    .foregroundStyle(palette.textPrimary)
                                    .stacklumeLineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(stat.count)")
                                    .stacklumeFont(.caption.weight(.semibold))
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Ritmo de guardado (barras por mes)

    private var monthlyChartCard: some View {
        chartCard("Guardados por mes", systemImage: "calendar") {
            Chart(monthlyStats) { stat in
                BarMark(x: .value("Mes", stat.label),
                        y: .value("Enlaces", stat.count))
                    .cornerRadius(5)
                    .foregroundStyle(palette.accent.gradient)
                    .annotation(position: .top) {
                        if stat.count > 0 {
                            Text("\(stat.count)")
                                .stacklumeFont(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2.scaled(by: StacklumeTextScale.normalizedFactor(textScale))).foregroundStyle(palette.textSecondary)
                }
            }
            .frame(height: 160)
        }
    }

    // MARK: - Dominios principales

    private var topDomainsCard: some View {
        chartCard("Dominios principales", systemImage: "globe") {
            VStack(spacing: 10) {
                ForEach(topDomains) { stat in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(stat.host)
                            .stacklumeFont(.caption)
                            .foregroundStyle(palette.textPrimary)
                            .stacklumeLineLimit(1)
                            .frame(width: 120, alignment: .leading)
                        GeometryReader { geo in
                            let ratio = maxDomainCount > 0 ? CGFloat(stat.count) / CGFloat(maxDomainCount) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(palette.accent.opacity(0.14))
                                Capsule().fill(palette.accent.gradient)
                                    .frame(width: max(14, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 14)
                        Text("\(stat.count)")
                            .stacklumeFont(.caption.weight(.semibold))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Estructura de tarjeta de gráfico

    @ViewBuilder
    private func chartCard<Content: View>(_ title: String, systemImage: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label(title, systemImage: systemImage)
                .stacklumeFont(.subheadline.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .stacklumeFont(.caption)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    // MARK: - Cálculos

    private var savedThisMonth: Int {
        let cal = Calendar.current
        let now = Date()
        return links.filter { cal.isDate($0.createdAt, equalTo: now, toGranularity: .month) }.count
    }

    /// Proporción de enlaces leídos (0–1).
    private var readProgress: Double {
        guard !links.isEmpty else { return 0 }
        return Double(links.filter(\.isRead).count) / Double(links.count)
    }

    /// Días consecutivos con al menos un enlace guardado. La racha sigue VIVA si guardaste
    /// HOY o AYER (no se resetea a 0 al pasar la medianoche): empieza a contar desde el
    /// último día con guardado y retrocede. Así no se castiga al usuario hasta perder un día entero.
    private var savingStreak: Int {
        let cal = Calendar.current
        let days = Set(links.map { cal.startOfDay(for: $0.createdAt) })
        let today = cal.startOfDay(for: Date())
        var day: Date
        if days.contains(today) {
            day = today
        } else if let yesterday = cal.date(byAdding: .day, value: -1, to: today), days.contains(yesterday) {
            day = yesterday
        } else {
            return 0
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// La racha está viva (cuenta desde ayer) pero HOY aún no has guardado nada: en riesgo.
    private var streakAtRisk: Bool {
        guard savingStreak > 0 else { return false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return !links.contains { cal.isDate($0.createdAt, inSameDayAs: today) }
    }

    /// Reparto por tipo de contenido (solo tipos con enlaces), de mayor a menor.
    private var contentTypeStats: [ContentTypeStat] {
        let grouped = Dictionary(grouping: links, by: \.contentType)
        return grouped
            .map { ContentTypeStat(name: $0.key.displayName, count: $0.value.count,
                                   color: contentTypeColor($0.key)) }
            .sorted { $0.count > $1.count }
    }

    private var maxContentTypeCount: Int { contentTypeStats.map(\.count).max() ?? 1 }

    private func contentTypeColor(_ type: ContentType) -> Color {
        switch type {
        case .video: Color(hex: "#EF4444")
        case .music: Color(hex: "#A855F7")
        case .game: Color(hex: "#22C55E")
        case .code: Color(hex: "#3B82F6")
        case .article: Color(hex: "#F59E0B")
        case .social: Color(hex: "#EC4899")
        case .design: Color(hex: "#8B5CF6")
        case .document: Color(hex: "#64748B")
        case .commerce: Color(hex: "#14B8A6")
        case .website: palette.accent
        }
    }

    /// Top 5 colecciones por nº de enlaces + «Sin clasificar» si procede.
    private var collectionStats: [CollectionStat] {
        var stats: [CollectionStat] = categories.compactMap { category in
            let count = links.filter { $0.category?.id == category.id }.count
            guard count > 0 else { return nil }
            return CollectionStat(name: category.name, count: count, color: Color(hex: category.colorHex))
        }
        .sorted { $0.count > $1.count }

        let uncategorized = links.filter { $0.category == nil }.count
        if uncategorized > 0 {
            stats.append(CollectionStat(name: "Sin clasificar", count: uncategorized,
                                        color: palette.textSecondary))
        }
        // Limita a 6 segmentos para legibilidad.
        if stats.count > 6 {
            let top = Array(stats.prefix(5))
            let rest = stats.dropFirst(5).reduce(0) { $0 + $1.count }
            return top + [CollectionStat(name: "Otras", count: rest, color: palette.textSecondary.opacity(0.5))]
        }
        return stats
    }

    /// Formateador de mes («LLL») reutilizado (crear un DateFormatter es costoso).
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "LLL"
        return f
    }()

    /// Enlaces guardados en cada uno de los últimos 6 meses (incluido el actual).
    private var monthlyStats: [MonthStat] {
        let cal = Calendar.current
        let now = Date()
        var result: [MonthStat] = []
        for offset in stride(from: 5, through: 0, by: -1) {
            guard let monthDate = cal.date(byAdding: .month, value: -offset, to: now) else { continue }
            let count = links.filter { cal.isDate($0.createdAt, equalTo: monthDate, toGranularity: .month) }.count
            let label = Self.monthFormatter.string(from: monthDate).capitalized
            result.append(MonthStat(label: label, count: count))
        }
        return result
    }

    private var topDomains: [DomainStat] {
        let grouped = Dictionary(grouping: links) { $0.url.urlHost }
        return grouped
            .map { DomainStat(host: $0.key, count: $0.value.count) }
            .filter { !$0.host.isEmpty }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }

    private var maxDomainCount: Int { topDomains.map(\.count).max() ?? 1 }
}

private struct CollectionStat: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
    let color: Color
}

private struct MonthStat: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
}

private struct DomainStat: Identifiable {
    var id: String { host }
    let host: String
    let count: Int
}

private struct ContentTypeStat: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
    let color: Color
}

/// Chips de tema en flujo (saltan de línea al no caber). Pocas y cortas: las del resumen
/// semanal. Reutiliza `FlowLayout` para no fijar un número de columnas.
private struct FlowChips: View {
    @Environment(\.themePalette) private var palette
    let items: [String]
    let tint: Color
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .stacklumeFont(.caption.weight(.medium))
                    .readableTint(tint, palette: palette, on: [palette.surface], overlay: tint.opacity(0.14))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }
        }
    }
}

/// Distribución en flujo: coloca las subvistas en fila y salta de línea cuando no caben en el
/// ancho propuesto. Mínima, para las pocas chips del resumen semanal (no es un layout general).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > bounds.width, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
