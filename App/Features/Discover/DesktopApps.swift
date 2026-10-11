import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

// MARK: - Categorías

/// Categoría de una app de escritorio (para filtrar y para el icono de respaldo).
enum AppCategory: String, CaseIterable, Identifiable, Hashable {
    case notas, desarrollo, basesDeDatos, seguridad, multimedia, audio
    case diseno, ofimatica, comunicacion, utilidades, redes, lectura, navegador

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notas: "Notas y conocimiento"
        case .desarrollo: "Desarrollo"
        case .basesDeDatos: "Bases de datos"
        case .seguridad: "Seguridad y privacidad"
        case .multimedia: "Multimedia y vídeo"
        case .audio: "Audio"
        case .diseno: "Imagen y diseño"
        case .ofimatica: "Ofimática"
        case .comunicacion: "Comunicación"
        case .utilidades: "Utilidades del sistema"
        case .redes: "Redes y descargas"
        case .lectura: "Lectura y ebooks"
        case .navegador: "Navegadores"
        }
    }

    /// Icono de respaldo (SF Symbol) cuando no carga ninguna imagen remota.
    var icon: String {
        switch self {
        case .notas: "note.text"
        case .desarrollo: "chevron.left.forwardslash.chevron.right"
        case .basesDeDatos: "cylinder.split.1x2.fill"
        case .seguridad: "lock.shield.fill"
        case .multimedia: "play.rectangle.fill"
        case .audio: "waveform"
        case .diseno: "paintbrush.pointed.fill"
        case .ofimatica: "doc.text.fill"
        case .comunicacion: "message.fill"
        case .utilidades: "wrench.and.screwdriver.fill"
        case .redes: "arrow.down.circle.fill"
        case .lectura: "books.vertical.fill"
        case .navegador: "globe"
        }
    }
}

// MARK: - Modelo

/// Una app de escritorio (macOS/Windows/Linux). Cubre tanto las open source de pago
/// como las gratuitas. El icono se obtiene de forma fiable con cascada: avatar del
/// propietario en GitHub (logo del proyecto) → favicon del sitio → símbolo de la
/// categoría.
struct DesktopApp: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let tagline: String
    let platforms: [Plat]
    let website: String
    let repo: String
    let pricing: String
    let isPaid: Bool
    let category: AppCategory

    enum Plat: String, Hashable { case mac = "macOS", windows = "Windows", linux = "Linux" }

    init(_ name: String, _ tagline: String, _ platforms: [Plat],
         web: String, repo: String = "", price: String, paid: Bool, _ category: AppCategory) {
        self.name = name; self.tagline = tagline; self.platforms = platforms
        self.website = web; self.repo = repo; self.pricing = price
        self.isPaid = paid; self.category = category
    }

    /// Candidatos de imagen de preview, en orden de preferencia. Primero el favicon
    /// del sitio (logo PROPIO de la app, p. ej. Krita/GIMP en vez del logo de KDE/
    /// GNOME del avatar de la org) y, como respaldo fiable, el avatar de GitHub.
    var iconCandidates: [String] {
        var c: [String] = PreviewImage.favicon(for: website, size: 128)
        if let avatar = PreviewImage.githubAvatar(forRepoURL: repo, size: 200) { c.append(avatar) }
        return c
    }
}

// MARK: - Catálogos curados

enum DesktopApps {
    /// Open source con modelo de PAGO (open core / pro / licencia / sync) — al estilo
    /// de Mole. Lista verificada.
    static let premium: [DesktopApp] = [
        .init("Mole", "Limpieza, desinstalador y monitor de disco para Mac.", [.mac],
              web: "https://mole.fit", repo: "https://github.com/tw93/Mole", price: "Pago único $19 · CLI gratis", paid: true, .utilidades),
        .init("Beekeeper Studio", "Cliente SQL moderno y gestor de bases de datos.", [.mac, .windows, .linux],
              web: "https://www.beekeeperstudio.io", repo: "https://github.com/beekeeper-studio/beekeeper-studio", price: "Open core · Pro de pago", paid: true, .basesDeDatos),
        .init("Bruno", "Cliente de APIs nativo basado en Git (alternativa a Postman).", [.mac, .windows, .linux],
              web: "https://www.usebruno.com", repo: "https://github.com/usebruno/bruno", price: "Gratis · Pro de pago", paid: true, .desarrollo),
        .init("DBeaver", "Gestor universal de bases de datos (100+ motores).", [.mac, .windows, .linux],
              web: "https://dbeaver.io", repo: "https://github.com/dbeaver/dbeaver", price: "Community gratis · PRO de pago", paid: true, .basesDeDatos),
        .init("Zed", "Editor de código ultrarrápido en Rust, con IA y colaboración.", [.mac, .linux],
              web: "https://zed.dev", repo: "https://github.com/zed-industries/zed", price: "Gratis · Pro $10/mes", paid: true, .desarrollo),
        .init("Warp", "Terminal moderno con IA, bloques y autocompletado.", [.mac, .windows, .linux],
              web: "https://www.warp.dev", repo: "https://github.com/warpdotdev/warp", price: "Gratis · plan de pago", paid: true, .desarrollo),
        .init("Mockoon", "Crea y sirve mocks de API en local, sin cuenta.", [.mac, .windows, .linux],
              web: "https://mockoon.com", repo: "https://github.com/mockoon/mockoon", price: "Desktop gratis · Cloud de pago", paid: true, .desarrollo),
        .init("Insomnia", "Cliente de APIs (REST, GraphQL, gRPC, WebSockets).", [.mac, .windows, .linux],
              web: "https://insomnia.rest", repo: "https://github.com/Kong/insomnia", price: "Gratis · planes de equipo", paid: true, .desarrollo),
        .init("Bitwarden", "Gestor de contraseñas con cifrado de extremo a extremo.", [.mac, .windows, .linux],
              web: "https://bitwarden.com", repo: "https://github.com/bitwarden/clients", price: "Gratis · Premium de pago", paid: true, .seguridad),
        .init("Cryptomator", "Cifra tus archivos antes de subirlos a la nube.", [.mac, .windows, .linux],
              web: "https://cryptomator.org", repo: "https://github.com/cryptomator/cryptomator", price: "Donación · licencia €29.99", paid: true, .seguridad),
        .init("Ente Photos", "Fotos cifradas E2E (alternativa privada a Google Photos).", [.mac, .windows, .linux],
              web: "https://ente.io", repo: "https://github.com/ente-io/ente", price: "10 GB gratis · planes de pago", paid: true, .multimedia),
        .init("AppFlowy", "Workspace tipo Notion con páginas, bases de datos e IA.", [.mac, .windows, .linux],
              web: "https://appflowy.com", repo: "https://github.com/AppFlowy-IO/AppFlowy", price: "Gratis · Pro de pago", paid: true, .notas),
        .init("AFFiNE", "Notas + pizarra + base de datos (Notion + Miro).", [.mac, .windows, .linux],
              web: "https://affine.pro", repo: "https://github.com/toeverything/AFFiNE", price: "Gratis · Pro/lifetime", paid: true, .notas),
        .init("Anytype", "Base de conocimiento local-first y cifrada E2E.", [.mac, .windows, .linux],
              web: "https://anytype.io", repo: "https://github.com/anyproto/anytype-ts", price: "Gratis · planes de pago", paid: true, .notas),
        .init("Logseq", "Notas en grafo, local-first (Markdown/Org).", [.mac, .windows, .linux],
              web: "https://logseq.com", repo: "https://github.com/logseq/logseq", price: "Gratis · Pro (sync) de pago", paid: true, .notas),
        .init("SiYuan", "Gestión del conocimiento por bloques, local-first.", [.mac, .windows, .linux],
              web: "https://b3log.org/siyuan/en", repo: "https://github.com/siyuan-note/siyuan", price: "Gratis · sync de pago", paid: true, .notas),
        .init("Standard Notes", "Notas privadas y cifradas E2E, multiplataforma.", [.mac, .windows, .linux],
              web: "https://standardnotes.com", repo: "https://github.com/standardnotes/app", price: "Gratis · planes de pago", paid: true, .notas),
        .init("Joplin", "Notas y tareas Markdown con cifrado y multi-sync.", [.mac, .windows, .linux],
              web: "https://joplinapp.org", repo: "https://github.com/laurent22/joplin", price: "App gratis · Cloud de pago", paid: true, .notas),
        .init("Notesnook", "Notas privadas cifradas (alternativa a Evernote).", [.mac, .windows, .linux],
              web: "https://notesnook.com", repo: "https://github.com/streetwriters/notesnook", price: "Gratis · Pro de pago", paid: true, .notas),
        .init("Penpot", "Diseño y prototipado colaborativo (alternativa a Figma).", [.mac, .windows, .linux],
              web: "https://penpot.app", repo: "https://github.com/penpot/penpot", price: "Gratis · Enterprise de pago", paid: true, .diseno),
        .init("Outline", "Wiki y base de conocimiento para equipos.", [.mac, .windows, .linux],
              web: "https://www.getoutline.com", repo: "https://github.com/outline/outline", price: "Self-host gratis · Cloud de pago", paid: true, .notas),
        .init("IntelliJ IDEA", "IDE de JetBrains para Java/Kotlin y más.", [.mac, .windows, .linux],
              web: "https://www.jetbrains.com/idea", repo: "https://github.com/JetBrains/intellij-community", price: "Community gratis · Ultimate de pago", paid: true, .desarrollo),
    ]

    /// Open source y GRATUITAS (donación opcional) — utilidades imprescindibles.
    static let free: [DesktopApp] = [
        .init("VLC", "Reproductor multimedia que abre casi cualquier formato.", [.mac, .windows, .linux],
              web: "https://www.videolan.org/vlc", repo: "https://github.com/videolan/vlc", price: "Gratis · GPL", paid: false, .multimedia),
        .init("OBS Studio", "Grabación y streaming en directo profesional.", [.mac, .windows, .linux],
              web: "https://obsproject.com", repo: "https://github.com/obsproject/obs-studio", price: "Gratis · GPL", paid: false, .multimedia),
        .init("HandBrake", "Conversor y transcodificador de vídeo.", [.mac, .windows, .linux],
              web: "https://handbrake.fr", repo: "https://github.com/HandBrake/HandBrake", price: "Gratis · GPL", paid: false, .multimedia),
        .init("Shotcut", "Editor de vídeo multipista, libre y multiplataforma.", [.mac, .windows, .linux],
              web: "https://shotcut.org", repo: "https://github.com/mltframework/shotcut", price: "Gratis · GPL", paid: false, .multimedia),
        .init("Kdenlive", "Editor de vídeo no lineal potente de KDE.", [.mac, .windows, .linux],
              web: "https://kdenlive.org", repo: "https://github.com/KDE/kdenlive", price: "Gratis · GPL", paid: false, .multimedia),
        .init("IINA", "Reproductor de vídeo moderno y nativo para Mac.", [.mac],
              web: "https://iina.io", repo: "https://github.com/iina/iina", price: "Gratis · GPL", paid: false, .multimedia),
        .init("Jellyfin Media Player", "Cliente de escritorio para tu servidor multimedia.", [.mac, .windows, .linux],
              web: "https://jellyfin.org", repo: "https://github.com/jellyfin/jellyfin-media-player", price: "Gratis · GPL", paid: false, .multimedia),
        .init("Audacity", "Editor y grabador de audio multipista.", [.mac, .windows, .linux],
              web: "https://www.audacityteam.org", repo: "https://github.com/audacity/audacity", price: "Gratis · GPL", paid: false, .audio),
        .init("Krita", "Pintura digital e ilustración profesional.", [.mac, .windows, .linux],
              web: "https://krita.org", repo: "https://github.com/KDE/krita", price: "Gratis · GPL", paid: false, .diseno),
        .init("Inkscape", "Editor de gráficos vectoriales (SVG).", [.mac, .windows, .linux],
              web: "https://inkscape.org", repo: "https://github.com/inkscape/inkscape", price: "Gratis · GPL", paid: false, .diseno),
        .init("GIMP", "Edición de imagen avanzada (alternativa a Photoshop).", [.mac, .windows, .linux],
              web: "https://www.gimp.org", repo: "https://github.com/GNOME/gimp", price: "Gratis · GPL", paid: false, .diseno),
        .init("Blender", "Suite 3D completa: modelado, animación y render.", [.mac, .windows, .linux],
              web: "https://www.blender.org", repo: "https://github.com/blender/blender", price: "Gratis · GPL", paid: false, .diseno),
        .init("darktable", "Revelado RAW y flujo fotográfico no destructivo.", [.mac, .windows, .linux],
              web: "https://www.darktable.org", repo: "https://github.com/darktable-org/darktable", price: "Gratis · GPL", paid: false, .diseno),
        .init("FreeCAD", "Modelado paramétrico 3D / CAD.", [.mac, .windows, .linux],
              web: "https://www.freecad.org", repo: "https://github.com/FreeCAD/FreeCAD", price: "Gratis · LGPL", paid: false, .diseno),
        .init("LibreOffice", "Suite ofimática completa (documentos, hojas, presentaciones).", [.mac, .windows, .linux],
              web: "https://www.libreoffice.org", repo: "https://github.com/LibreOffice/core", price: "Gratis · MPL", paid: false, .ofimatica),
        .init("Signal", "Mensajería privada con cifrado de extremo a extremo.", [.mac, .windows, .linux],
              web: "https://signal.org", repo: "https://github.com/signalapp/Signal-Desktop", price: "Gratis · AGPL", paid: false, .comunicacion),
        .init("Telegram Desktop", "Cliente de escritorio de Telegram, rápido y abierto.", [.mac, .windows, .linux],
              web: "https://desktop.telegram.org", repo: "https://github.com/telegramdesktop/tdesktop", price: "Gratis · GPL", paid: false, .comunicacion),
        .init("Element", "Chat seguro y descentralizado sobre Matrix.", [.mac, .windows, .linux],
              web: "https://element.io", repo: "https://github.com/element-hq/element-desktop", price: "Gratis · AGPL", paid: false, .comunicacion),
        .init("Thunderbird", "Cliente de correo, calendario y contactos de Mozilla.", [.mac, .windows, .linux],
              web: "https://www.thunderbird.net", repo: "", price: "Gratis · MPL", paid: false, .comunicacion),
        .init("KeePassXC", "Gestor de contraseñas local, sin nube.", [.mac, .windows, .linux],
              web: "https://keepassxc.org", repo: "https://github.com/keepassxreboot/keepassxc", price: "Gratis · GPL", paid: false, .seguridad),
        .init("VeraCrypt", "Cifrado de disco y volúmenes (sucesor de TrueCrypt).", [.mac, .windows, .linux],
              web: "https://www.veracrypt.fr", repo: "https://github.com/veracrypt/VeraCrypt", price: "Gratis · Apache/GPL", paid: false, .seguridad),
        .init("qBittorrent", "Cliente BitTorrent ligero y sin anuncios.", [.mac, .windows, .linux],
              web: "https://www.qbittorrent.org", repo: "https://github.com/qbittorrent/qBittorrent", price: "Gratis · GPL", paid: false, .redes),
        .init("Transmission", "Cliente BitTorrent minimalista y nativo.", [.mac, .linux],
              web: "https://transmissionbt.com", repo: "https://github.com/transmission/transmission", price: "Gratis · GPL/MIT", paid: false, .redes),
        .init("Cyberduck", "Cliente FTP/SFTP/S3 y almacenamiento en la nube.", [.mac, .windows],
              web: "https://cyberduck.io", repo: "https://github.com/iterate-ch/cyberduck", price: "Gratis · GPL", paid: false, .redes),
        .init("Calibre", "Gestor y conversor de ebooks todo en uno.", [.mac, .windows, .linux],
              web: "https://calibre-ebook.com", repo: "https://github.com/kovidgoyal/calibre", price: "Gratis · GPL", paid: false, .lectura),
        .init("Zotero", "Gestor de referencias e investigación.", [.mac, .windows, .linux],
              web: "https://www.zotero.org", repo: "https://github.com/zotero/zotero", price: "Gratis · AGPL", paid: false, .lectura),
        .init("NetNewsWire", "Lector de RSS nativo, rápido y elegante.", [.mac],
              web: "https://netnewswire.com", repo: "https://github.com/Ranchero-Software/NetNewsWire", price: "Gratis · MIT", paid: false, .lectura),
        .init("Maccy", "Historial de portapapeles ligero para Mac.", [.mac],
              web: "https://maccy.app", repo: "https://github.com/p0deje/Maccy", price: "Gratis · MIT", paid: false, .utilidades),
        .init("AltTab", "Cambiador de ventanas estilo Windows para Mac.", [.mac],
              web: "https://alt-tab-macos.netlify.app", repo: "https://github.com/lwouis/alt-tab-macos", price: "Gratis · GPL", paid: false, .utilidades),
        .init("Rectangle", "Organiza ventanas con atajos y zonas.", [.mac],
              web: "https://rectangleapp.com", repo: "https://github.com/rxhanson/Rectangle", price: "Gratis · MIT", paid: false, .utilidades),
        .init("Stats", "Monitor del sistema en la barra de menús.", [.mac],
              web: "https://github.com/exelban/stats", repo: "https://github.com/exelban/stats", price: "Gratis · MIT", paid: false, .utilidades),
        .init("balenaEtcher", "Graba imágenes a USB/SD de forma segura.", [.mac, .windows, .linux],
              web: "https://etcher.balena.io", repo: "https://github.com/balena-io/etcher", price: "Gratis · Apache", paid: false, .utilidades),
        .init("PowerToys", "Utilidades de productividad para Windows.", [.windows],
              web: "https://learn.microsoft.com/windows/powertoys", repo: "https://github.com/microsoft/PowerToys", price: "Gratis · MIT", paid: false, .utilidades),
        .init("ShareX", "Capturas y grabación de pantalla avanzadas (Windows).", [.windows],
              web: "https://getsharex.com", repo: "https://github.com/ShareX/ShareX", price: "Gratis · GPL", paid: false, .utilidades),
        .init("Notepad++", "Editor de texto y código ligero para Windows.", [.windows],
              web: "https://notepad-plus-plus.org", repo: "https://github.com/notepad-plus-plus/notepad-plus-plus", price: "Gratis · GPL", paid: false, .desarrollo),
        .init("VSCodium", "VS Code sin telemetría ni marca de Microsoft.", [.mac, .windows, .linux],
              web: "https://vscodium.com", repo: "https://github.com/VSCodium/vscodium", price: "Gratis · MIT", paid: false, .desarrollo),
        .init("Firefox", "Navegador centrado en privacidad y estándares abiertos.", [.mac, .windows, .linux],
              web: "https://www.mozilla.org/firefox", repo: "https://github.com/mozilla-firefox/firefox", price: "Gratis · MPL", paid: false, .navegador),
        .init("Brave", "Navegador Chromium que bloquea anuncios y rastreadores.", [.mac, .windows, .linux],
              web: "https://brave.com", repo: "https://github.com/brave/brave-browser", price: "Gratis · MPL", paid: false, .navegador),
        .init("RawTherapee", "Revelado RAW de alta calidad (alternativa a Lightroom).", [.mac, .windows, .linux],
              web: "https://www.rawtherapee.com", repo: "https://github.com/RawTherapee/RawTherapee", price: "Gratis · GPL", paid: false, .diseno),
        .init("LosslessCut", "Corta y une vídeo/audio sin recodificar (sin pérdida).", [.mac, .windows, .linux],
              web: "https://losslesscut.app", repo: "https://github.com/mifi/lossless-cut", price: "Gratis · GPL", paid: false, .multimedia),
        .init("MKVToolNix", "Crea, edita e inspecciona archivos Matroska (MKV).", [.mac, .windows, .linux],
              web: "https://mkvtoolnix.download", repo: "", price: "Gratis · GPL", paid: false, .multimedia),
        .init("Syncthing", "Sincroniza archivos entre dispositivos, sin nube.", [.mac, .windows, .linux],
              web: "https://syncthing.net", repo: "https://github.com/syncthing/syncthing", price: "Gratis · MPL", paid: false, .redes),
        .init("Motrix", "Gestor de descargas (HTTP, FTP, BitTorrent, Magnet).", [.mac, .windows, .linux],
              web: "https://motrix.app", repo: "https://github.com/agalwood/Motrix", price: "Gratis · MIT", paid: false, .redes),
        .init("Wireshark", "Analizador de protocolos de red de referencia.", [.mac, .windows, .linux],
              web: "https://www.wireshark.org", repo: "", price: "Gratis · GPL", paid: false, .redes),
        .init("Flameshot", "Capturas de pantalla con anotaciones.", [.mac, .windows, .linux],
              web: "https://flameshot.org", repo: "https://github.com/flameshot-org/flameshot", price: "Gratis · GPL", paid: false, .utilidades),
    ]
}

// MARK: - Fila (lista)

/// Fila de una app: icono remoto (avatar/favicon con respaldo a símbolo), nombre,
/// badges de plataforma y chip de precio en su propia línea.
struct DesktopAppRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let app: DesktopApp
    var expanded: Bool = false

    var body: some View {
        let content = HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            SecureRemoteImage(candidates: app.iconCandidates) {
                Image(systemName: app.category.icon)
                    .scaledFont(13, weight: .semibold, scalesWithText: false)
                    .foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.accent.opacity(0.12))
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .stacklumeFont(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                        .stacklumeLineLimit(1)
                    Spacer(minLength: 6)
                    ForEach(app.platforms, id: \.self) { plat in
                        Text(plat.rawValue)
                            .stacklumeFont(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(palette.textSecondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize()
                    }
                }
                Text(app.tagline)
                    .stacklumeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(expanded ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(app.pricing)
                    .stacklumeFont(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((app.isPaid ? palette.accent : Color(hex: "#22C55E")).opacity(0.16), in: Capsule())
                    .foregroundStyle(app.isPaid ? palette.accent : Color(hex: "#22C55E"))
                    .stacklumeLineLimit(1)
            }
        }
        content.discoverRow(url: app.website, title: app.name, imageURL: app.iconCandidates.first) {
            if let url = StacklumeAutomationPolicy.openableStoredURL(app.website) { openURL(url) }
        }
    }
}

// MARK: - Mosaico (galería)

/// Mosaico de una app para la vista de galería: portada 16:9 real (captura/hero del
/// sitio vía `og:image`, con respaldo a un placeholder de marca) y un pie con icono,
/// nombre, precio y plataformas. Clic abre el sitio; clic derecho guarda/copia.
struct DesktopAppTile: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL
    let app: DesktopApp

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { OpenGraphCover(website: app.website) { coverPlaceholder } }
                .clipped()

            HStack(alignment: .top, spacing: 8) {
                SecureRemoteImage(candidates: app.iconCandidates) {
                    Image(systemName: app.category.icon)
                        .scaledFont(13, weight: .semibold, scalesWithText: false)
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.accent.opacity(0.12))
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .stacklumeFont(.caption.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                        .stacklumeLineLimit(1)
                    Text(app.pricing)
                        .scaledFont(9, weight: .semibold)
                        .foregroundStyle(app.isPaid ? palette.accent : Color(hex: "#22C55E"))
                        .stacklumeLineLimit(1)
                    Text(app.platforms.map(\.rawValue).joined(separator: " · "))
                        .scaledFont(9)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        content
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .discoverRow(url: app.website, title: app.name, imageURL: app.iconCandidates.first) {
                if let url = StacklumeAutomationPolicy.openableStoredURL(app.website) { openURL(url) }
            }
    }

    /// Respaldo de portada (DESIGN.md §9): superficie oscura + susurro radial de marca
    /// + glifo de categoría apagado. Nunca el degradado diagonal saturado.
    private var coverPlaceholder: some View {
        ZStack {
            palette.surface
            RadialGradient(colors: [palette.accent.opacity(0.18), .clear],
                           center: .center, startRadius: 2, endRadius: 110)
            Image(systemName: app.category.icon)
                .scaledFont(26, weight: .semibold, scalesWithText: false)
                .foregroundStyle(palette.accent.opacity(0.45))
        }
    }
}

/// Cuadrícula de mosaicos de apps (carga muchas a la vez). Columnas anchas para que
/// la portada 16:9 luzca como captura, no como miniatura.
struct DesktopAppGallery: View {
    let apps: [DesktopApp]
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 14, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(apps) { DesktopAppTile(app: $0) }
        }
    }
}

// MARK: - Widget compacto (con variación)

/// Widget compacto de un catálogo de apps. Baraja en cada aparición para que el
/// contenido VAYA VARIANDO entre visitas (lista estática, sin red → instantáneo) y
/// ofrece un filtro de categoría en una barra de chips deslizable.
struct DesktopAppsWidgetContent: View {
    @Environment(\.themePalette) private var palette
    let catalog: [DesktopApp]
    var size: WidgetSize = .extraLarge

    /// Catálogo barajado una vez por aparición (la «variación»).
    @State private var ordered: [DesktopApp] = []
    /// Categoría seleccionada en los chips (nil = todas).
    @State private var category: AppCategory?

    private var limit: Int {
        switch size {
        case .extraLarge: 7
        case .large: 5
        case .medium, .wide: 3
        default: 3
        }
    }

    private var shown: [DesktopApp] {
        guard let category else { return ordered }
        return ordered.filter { $0.category == category }
    }

    private var availableCategories: [AppCategory] {
        AppCategory.allCases.filter { c in catalog.contains { $0.category == c } }
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            categoryBar
            Group {
                if ordered.isEmpty {
                    Color.clear
                } else if shown.isEmpty {
                    Text("Sin apps en esta categoría")
                        .stacklumeFont(.caption2).foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DiscoverList(items: shown, limit: limit) { DesktopAppRow(app: $0) }
                }
            }
        }
        .task { if ordered.isEmpty { ordered = catalog.shuffled() } }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Todas", selected: category == nil) { category = nil }
                ForEach(availableCategories) { cat in
                    chip(cat.title, selected: category == cat) {
                        category = (category == cat) ? nil : cat
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .stacklumeFont(.caption2.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background((selected ? palette.accent : palette.textSecondary)
                    .opacity(selected ? 0.18 : 0.12), in: Capsule())
                .foregroundStyle(selected ? palette.accent : palette.textSecondary)
        }
        .buttonStyle(.plain)
        .themedHelp("Filtrar por \(label)")
    }
}

// MARK: - Vista ampliada (Lista / Galería + filtros)

/// Hoja ampliada de un catálogo de apps con conmutador Lista/Galería y filtros de
/// plataforma y categoría. La galería carga muchas apps a la vez.
struct DesktopAppsDetailView: View {
    let catalog: [DesktopApp]
    let title: String
    let icon: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var platform: DesktopApp.Plat?
    @State private var category: AppCategory?
    @State private var mode: ViewMode = .galeria

    enum ViewMode: String, CaseIterable { case galeria, lista }

    private var filtered: [DesktopApp] {
        catalog.filter { app in
            (platform == nil || app.platforms.contains(platform!)) &&
            (category == nil || app.category == category)
        }
    }

    private var availableCategories: [AppCategory] {
        AppCategory.allCases.filter { c in catalog.contains { $0.category == c } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.4))
            controls
            Divider().overlay(palette.border.opacity(0.4))
            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.title3)
                    Text("No hay apps con estos filtros").stacklumeFont(.caption)
                }
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if mode == .galeria {
                        DesktopAppGallery(apps: filtered).padding(16)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(filtered) { app in
                                HStack(alignment: .top, spacing: 12) {
                                    DesktopAppRow(app: app, expanded: true)
                                    DiscoverSaveButton(url: app.website, title: app.name, imageURL: app.iconCandidates.first)
                                }
                                Divider().overlay(palette.border.opacity(0.4))
                            }
                        }
                        .padding(16)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .background(palette.background)
        .environment(\.discoverExpandAction, nil)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(palette.accent)
            Text(title).stacklumeFont(.headline).foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            Button("Cerrar") { dismiss() }.tint(palette.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Vista", selection: $mode) {
                    Text("Galería").tag(ViewMode.galeria)
                    Text("Lista").tag(ViewMode.lista)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                .accessibilityLabel("Modo de vista")
                .themedHelp("Alternar entre galería y lista")
                Spacer()
                Text("\(filtered.count) apps")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            HStack(spacing: 12) {
                Picker("Plataforma", selection: $platform) {
                    Text("Todas").tag(DesktopApp.Plat?.none)
                    ForEach([DesktopApp.Plat.mac, .windows, .linux], id: \.self) { plat in
                        Text(plat.rawValue).tag(DesktopApp.Plat?.some(plat))
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                .accessibilityLabel("Filtrar por plataforma")
                .themedHelp("Filtrar apps por plataforma")
                Picker("Categoría", selection: $category) {
                    Text("Todas las categorías").tag(AppCategory?.none)
                    ForEach(availableCategories) { cat in
                        Text(cat.title).tag(AppCategory?.some(cat))
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                .accessibilityLabel("Filtrar por categoría")
                .themedHelp("Filtrar apps por categoría")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
