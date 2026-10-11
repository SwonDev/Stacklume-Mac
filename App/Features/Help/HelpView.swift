import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Ventana de Ayuda nativa (menú Ayuda · ⌘?). Guía de uso premium + referencia de
/// atajos de teclado. Como la escena `Window` NO hereda el entorno de la ventana
/// principal, inyectamos aquí el tema activo (igual que `SettingsView`).
struct HelpView: View {
    /// Identificador de la escena `Window` para abrirla con `openWindow(id:)`.
    static let windowID = "stacklume-help"

    @Environment(\.colorScheme) private var systemScheme
    @Query private var settings: [AppSettings]

    private var theme: Theme {
        Theme(rawValue: settings.first?.themeID ?? "dark") ?? .dark
    }

    var body: some View {
        HelpContent()
            .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 720)
            .stacklumeTheme(theme, systemScheme: systemScheme)
            .preferredColorScheme(theme.preferredColorScheme)
            .tooltipLayer(theme.palette(systemScheme: systemScheme))
    }
}

/// Contenido de la ayuda (separado para poder leer `themePalette` ya inyectado).
private struct HelpContent: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header

                guideSection(
                    title: "Guarda enlaces sin esfuerzo",
                    items: [
                        ("plus.circle.fill", "Nuevo enlace", "Pulsa «Nuevo enlace» o ⌘N y pega la URL. Stacklume detecta la plataforma y rellena título, descripción e imagen."),
                        ("arrow.down.doc.fill", "Arrastra y suelta", "Arrastra cualquier URL (o varias) a la ventana para añadirlas de golpe."),
                        ("doc.on.clipboard.fill", "Desde el portapapeles", "Actívalo en Ajustes › Privacidad para que, al copiar una URL fuera de la app, aparezca un aviso sutil para añadirla con un clic."),
                        ("safari.fill", "Compartir desde Safari", "Usa la extensión de compartir de macOS para enviar la página a Stacklume."),
                    ]
                )

                guideSection(
                    title: "Organiza tu universo",
                    items: [
                        ("folder.fill", "Colecciones", "Árbol jerárquico en la barra lateral. Arrastra para anidar o reordenar, y crea subcolecciones."),
                        ("number", "Etiquetas", "Clasifica de forma transversal con etiquetas de color."),
                        ("tray.full.fill", "Bandeja", "Revisa las capturas pendientes una a una o en lote: clasifica, etiqueta, añade a lectura, marca como leído o archiva."),
                        ("star.fill", "Favoritos y cola", "Marca ★ favoritos y mantén una cola de lectura de lo pendiente."),
                        ("line.3.horizontal.decrease.circle", "Filtros inteligentes", "Artículos, vídeos, enlaces rotos, recordatorios y archivados, al instante."),
                    ]
                )

                guideSection(
                    title: "Asistente Liquid on-device",
                    items: [
                        ("sparkles", "Enriquecido con IA", "El modelo Liquid (privado, en tu Mac) mejora títulos, redacta descripciones, propone colección y etiquetas, y traduce al español."),
                        ("wand.and.stars", "Mejorar una colección", "Clic derecho sobre una colección › «Mejorar con IA» para enriquecer solo sus enlaces."),
                        ("brain.head.profile", "Cargar el modelo", "Actívalo en Ajustes › IA. El modelo elegido NO se cambia: tú mandas."),
                    ]
                )

                guideSection(
                    title: "Lee y visualiza a tu manera",
                    items: [
                        ("rectangle.grid.1x2", "Cuatro vistas", "Lista, Cuadrícula, Moodboard y Titulares. Cambia con el botón de la barra superior."),
                        ("magnifyingglass", "Búsqueda semántica", "Busca por significado, no solo por palabras exactas. Guarda búsquedas frecuentes."),
                        ("point.3.connected.trianglepath.dotted", "Conexiones", "Explora un mapa local de enlaces relacionados, entiende por qué se conectan y salta entre ideas sin perder el camino."),
                        ("book.fill", "Lector sin conexión", "Guarda el contenido para leerlo aunque la página desaparezca, y resáltalo."),
                        ("command", "Paleta de comandos", "Pulsa ⌘K para buscar, navegar y actuar desde cualquier sitio."),
                    ]
                )

                guideSection(
                    title: "Conecta y saca más partido",
                    items: [
                        ("at", "Integración con X", "Abre «X» en la barra lateral (⌘6), inicia sesión y navega. Al guardar un tweet se añade a tu biblioteca (su enlace si lo lleva). «Importar guardados» trae los que ya tenías; «Resolver enlaces» rescata el enlace de los tweets con tarjeta."),
                        ("square.stack.3d.up", "Agrupar por", "En Lista, Titulares y Cuadrícula, agrupa los enlaces por colección, dominio, tipo o fecha desde el menú «Agrupar»."),
                        ("highlighter", "Resaltar al leer", "Tanto en el navegador integrado como en el lector, selecciona texto y elige un color para guardarlo como resaltado. Reúnelos todos en «Resaltados» (⌘5) y expórtalos a Markdown."),
                        ("arrow.down.circle", "Copia sin conexión automática", "Actívala en Ajustes › Datos para que Stacklume guarde en segundo plano una copia legible de cada enlace."),
                    ]
                )

                guideSection(
                    title: "Automatiza con privacidad",
                    items: [
                        ("shortcut", "Acciones para Atajos", "Busca «Stacklume» en la app Atajos. Captura, consulta y organización se conceden o revocan por separado en Ajustes › Privacidad."),
                        ("point.3.connected.trianglepath.dotted", "Flujos encadenables", "«Obtener enlaces de Stacklume» devuelve resultados con título, URL, colección, etiquetas y estados para pasarlos directamente a la siguiente acción."),
                        ("lock.shield.fill", "Biblioteca protegida", "La automatización no abre servidores ni puertos, no expone notas, resaltados, contenido offline o rutas locales y no incluye borrado. El registro local tampoco guarda URLs, títulos ni búsquedas."),
                    ]
                )

                shortcutsSection
                resetNote

                Text("¿Más dudas? Visita stacklume.app · Hecho con cariño en Canarias por SwonDev.")
                    .stacklumeFont(.footnote)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.top, DesignSystem.Spacing.sm)
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackground())
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image("StacklumeLogo")
                .resizable().scaledToFit()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: palette.accent.opacity(0.35), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ayuda de Stacklume")
                    .stacklumeFont(.largeTitle.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                Text("Tu universo de enlaces, organizado. Aquí tienes todo lo que puedes hacer.")
                    .stacklumeFont(.title3)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sección de guía (tarjeta con lista de funciones)

    private func guideSection(title: String, items: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .stacklumeFont(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().overlay(palette.border.opacity(0.5)) }
                    featureRow(icon: item.0, title: item.1, description: item.2)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .background(palette.surface,
                        in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(palette.accent)
                .frame(width: 34, height: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Text(description)
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    // MARK: - Atajos de teclado

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Atajos de teclado")
                .stacklumeFont(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(HelpContent.shortcuts.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().overlay(palette.border.opacity(0.5)) }
                    shortcutRow(keys: item.0, description: item.1)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .background(palette.surface,
                        in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    /// Atajos reales declarados en `StacklumeCommands` + estándar de macOS.
    static let shortcuts: [(String, String)] = [
        ("⌘N", "Nuevo enlace"),
        ("⇧⌘N", "Nueva colección"),
        ("⌥⌘I", "Importar pestañas abiertas"),
        ("⌘K", "Buscar (paleta de comandos)"),
        ("⌃⌘S", "Guardar el enlace del portapapeles (global, sin abrir la app)"),
        ("⌘O / ⏎", "Abrir el enlace seleccionado"),
        ("⌘Y / Espacio", "Vista rápida del enlace seleccionado (sin salir de la app)"),
        ("⌘Z / ⇧⌘Z", "Deshacer / Rehacer"),
        ("⌘E", "Editar el enlace seleccionado"),
        ("⌘D", "Marcar/quitar favorito"),
        ("⌘U", "Marcar como leído / pendiente"),
        ("⇧⌘A", "Archivar / desarchivar"),
        ("⇧⌘C", "Copiar enlace(s)"),
        ("⌥⌘C", "Copiar como Markdown"),
        ("⌘⌫", "Mover a la papelera"),
        ("⌘1", "Ir a Todos"),
        ("⌘2", "Ir a Favoritos"),
        ("⌘3", "Ir a Cola de lectura"),
        ("⌘4", "Ir a Sin clasificar"),
        ("⌘5", "Ir a Resaltados"),
        ("⌘6", "Ir a X"),
        ("⌘7", "Ir a Bandeja"),
        ("⌘0", "Ir a Descubrir"),
        ("⌃⌘1 – ⌃⌘4", "Vista: Lista / Cuadrícula / Moodboard / Titulares"),
        ("⌘,", "Ajustes"),
        ("⌘?", "Esta ayuda"),
        ("⌘W", "Cerrar ventana"),
        ("⌘Q", "Salir de Stacklume"),
    ]

    private func shortcutRow(keys: String, description: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Text(keys)
                .stacklumeFont(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .frame(minWidth: 56, alignment: .leading)
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(palette.background,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.border.opacity(0.6), lineWidth: 0.5)
                )
            Text(description)
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    // MARK: - Nota de restablecer

    private var resetNote: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color(hex: "#F0A030"))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Empezar de cero")
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Text("En Ajustes › Datos › Zona de peligro puedes restablecer la app: borra todos tus enlaces, colecciones y etiquetas para empezar limpio. Tus preferencias (tema, idioma) se conservan.")
                    .stacklumeFont(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
        .background(Color(hex: "#F0A030").opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .strokeBorder(Color(hex: "#F0A030").opacity(0.35), lineWidth: 0.5)
        )
    }
}
