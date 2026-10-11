import Foundation
import StacklumeCore

/// Import/export en formato HTML Netscape (el estándar de marcadores de los
/// navegadores: Chrome, Firefox, Safari…).
@MainActor
public enum NetscapeBookmarks {

    public static func export(_ links: [Bookmark]) -> String {
        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Stacklume</H1>
        <DL><p>

        """
        for link in links where link.deletedAt == nil {
            let addDate = Int(link.createdAt.timeIntervalSince1970)
            html += "    <DT><A HREF=\"\(escape(link.url))\" ADD_DATE=\"\(addDate)\">\(escape(link.title))</A>\n"
        }
        html += "</DL><p>\n"
        return html
    }

    /// Extrae los pares (URL, título) de un HTML de marcadores.
    public static func parse(_ html: String) -> [(url: String, title: String)] {
        let pattern = "<A\\s+[^>]*HREF=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</A>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            let url = String(html[urlRange])
            let rawTitle = String(html[titleRange])
            let title = unescape(stripTags(rawTitle)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("http") else { return nil }
            return (url, title.isEmpty ? url : title)
        }
    }

    // MARK: - Utilidades

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
