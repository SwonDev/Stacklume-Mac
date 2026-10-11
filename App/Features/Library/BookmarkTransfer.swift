import SwiftUI
import UniformTypeIdentifiers
import StacklumeCore

/// Carga arrastrable de un enlace. Ofrece TRES representaciones:
///  - Texto «bm:UUID» (preferida para destinos internos): para MOVER el enlace a una
///    colección DENTRO de la app. El sidebar la distingue del arrastre de colecciones
///    (que usa el UUID pelado).
///  - Archivo `.webloc` (para el Finder/escritorio): un marcador de internet NATIVO de
///    macOS, con el TÍTULO del enlace como nombre del archivo (no la URL fea). Al hacer
///    doble clic abre la página en el navegador. Es el «atajo web» que crea Safari.
///  - URL (para el navegador u otras apps): suelta el enlace como weblink.
///
/// El texto va primero (preferido) para que el destino interno —el `dropDestination` del
/// sidebar, que pide `String`— reciba siempre la etiqueta y nunca falle por preferir la
/// URL; los destinos de archivo (Finder) toman el `.webloc` con su nombre bonito y los
/// que piden `URL` (navegadores) obtienen la última representación.
struct BookmarkTransfer: Transferable {
    let id: UUID
    let urlString: String
    let title: String

    init(id: UUID, urlString: String, title: String = "") {
        self.id = id
        self.urlString = urlString
        self.title = title
    }

    init(from link: Bookmark) {
        self.id = link.id
        self.urlString = link.url
        self.title = link.title
    }

    /// Prefijo que marca un arrastre de ENLACE (vs. de colección) en el sidebar.
    static let tagPrefix = "bm:"
    var tag: String { Self.tagPrefix + id.uuidString }

    /// Extrae el UUID del enlace de una carga de texto, si tiene el prefijo «bm:».
    static func bookmarkID(from payload: String) -> UUID? {
        guard payload.hasPrefix(tagPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(tagPrefix.count)))
    }

    /// Tipo de los marcadores de internet de macOS (los `.webloc`). Está registrado en el
    /// sistema; el `?? .url` es una red de seguridad teórica para no forzar el desempaquetado.
    static let weblocType = UTType("com.apple.web-internet-location") ?? .url

    /// Contenido `plist` de un `.webloc`: un diccionario con la clave `URL`. Es el formato
    /// EXACTO que escribe Safari al arrastrar una pestaña al escritorio.
    var weblocData: Data {
        (try? PropertyListSerialization.data(fromPropertyList: ["URL": urlString],
                                             format: .xml, options: 0)) ?? Data()
    }

    /// Nombre de archivo seguro para el `.webloc`: el título del enlace (recortado y sin
    /// caracteres que el sistema de archivos prohíbe), o el dominio si no hay título. La
    /// extensión `.webloc` la añade el sistema a partir del tipo de contenido.
    var fileName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? (URL(string: urlString)?.host() ?? "Enlace") : trimmed
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
        return String(safe.prefix(80))
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (b: BookmarkTransfer) -> String in b.tag })
        DataRepresentation(exportedContentType: BookmarkTransfer.weblocType) { b in
            b.weblocData
        }
        .suggestedFileName { (b: BookmarkTransfer) in b.fileName }
        ProxyRepresentation(exporting: { (b: BookmarkTransfer) -> URL in
            URL(string: b.urlString) ?? URL(string: "https://stacklume.app")!
        })
    }
}
