import Foundation

/// Limpia ruido NO-prosa (CSS, restos de `<style>`/`<script>`, etiquetas sueltas) de un texto ya
/// extraído, para que la LECTURA EN VOZ ALTA y los RESÚMENES con IA lean SOLO contenido legible.
/// Algunas páginas-app (SPAs como Steam) filtran sus estilos al texto plano —p. ej. arranca con
/// «css{ color-scheme: dark light;} body {…}»—; esto lo elimina. Conservador: pensado para texto
/// que YA debería ser prosa pero arrastra estilos; no transforma prosa normal.
enum ProseText {

    /// Devuelve `raw` sin bloques CSS ni etiquetas sueltas. Atajo: si no hay `{` ni `<`, no hay
    /// nada que limpiar y se devuelve tal cual (la prosa normal no paga coste).
    static func clean(_ raw: String) -> String {
        guard raw.contains("{") || raw.contains("<") else { return raw }
        var text = raw

        // 1) Restos crudos de <style>/<script> (con sus etiquetas), por si llegaron sin procesar.
        text = text.replacing(#/(?is)<style\b[^>]*>.*?</style>/#, with: " ")
        text = text.replacing(#/(?is)<script\b[^>]*>.*?</script>/#, with: " ")

        // 2) Reglas CSS completas «selector { … }». El selector es corto y NO cruza `;` ni salto
        //    de línea, así no se traga prosa que tuviera una llave suelta lejana. Varias pasadas
        //    por el anidamiento (`@media { selector { … } }`).
        for _ in 0..<5 {
            let next = text.replacing(#/[^{};\n]{0,160}\{[^{}]{0,5000}\}/#, with: " ")
            if next == text { break }
            text = next
        }

        // 3) Comentarios y etiquetas HTML sueltas.
        text = text.replacing(#/<!--[^>]{0,2000}-->/#, with: " ")
        text = text.replacing(#/<[^>\n]{1,200}>/#, with: " ")

        // 4) Colapsar espacios y líneas.
        text = text.replacing(#/[ \t]{2,}/#, with: " ")
        text = text.replacing(#/\n[ \t]+/#, with: "\n")
        text = text.replacing(#/\n{3,}/#, with: "\n\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
