import Foundation

/// Mejora la resolución de las URLs de imágenes de preview cuando se reconoce el patrón,
/// para que las portadas se ADQUIERAN/MUESTREN en alta definición: quita parámetros de
/// reducción de tamaño y sube a la variante de máxima resolución conocida por la CDN o
/// plataforma. Best-effort y NO destructivo: devuelve candidatos de mayor a menor
/// resolución (la app los prueba en orden y cae al original si el HD no existe).
///
/// Nota: si el ORIGEN solo publica una imagen pequeña (p. ej. un box-art de 285 px), no
/// hay magia posible — una imagen de baja resolución no se vuelve HD ampliándola. Esto
/// solo recupera la versión grande cuando la CDN la ofrece tras un patrón reconocible.
enum HDImage {
    /// Candidatos `[HD, original]` para `RemoteImage` (que prueba en orden). Vacío si no
    /// hay URL. Dedup preservando el orden.
    static func candidates(_ urlString: String?) -> [String?] {
        guard let s = urlString, !s.isEmpty else { return [] }
        var out: [String] = []
        if let up = upgraded(s) { out.append(up) }
        out.append(s)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }.map { Optional($0) }
    }

    /// Versión de mayor resolución de una URL si se reconoce el patrón; si no, `nil`.
    static func upgraded(_ s: String) -> String? {
        // YouTube: hqdefault/mqdefault/sddefault/default → maxresdefault.
        if s.contains("ytimg.com") || s.contains("youtube.com/vi") {
            for low in ["hqdefault", "sddefault", "mqdefault", "default"] where s.contains(low) {
                return s.replacingOccurrences(of: low, with: "maxresdefault")
            }
        }
        // Google/algunas CDN: sufijo `=s400`/`=s400-c` (o `=w400-h300`) → máxima resolución.
        if let r = s.range(of: #"=(s\d+|w\d+-h\d+)(-c)?$"#, options: .regularExpression) {
            return s.replacingCharacters(in: r, with: "=s2048")
        }
        // Parámetros de query de reducción de tamaño (w/width/h/height/size/quality/resize…):
        // quitarlos suele devolver la imagen original a resolución completa.
        if var comps = URLComponents(string: s), let items = comps.queryItems, !items.isEmpty {
            let drop: Set<String> = ["w", "width", "h", "height", "size", "fit",
                                     "q", "quality", "resize", "dpr", "px"]
            let kept = items.filter { !drop.contains($0.name.lowercased()) }
            if kept.count != items.count {
                comps.queryItems = kept.isEmpty ? nil : kept
                if let str = comps.string { return str }
            }
        }
        return nil
    }
}
