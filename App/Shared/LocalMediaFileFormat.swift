import Foundation

/// Reconoce el contenedor original sin transcodificar ni depender de su antiguo nombre.
enum LocalMediaFileFormat {
    static func fileExtension(for data: Data, kind: String) -> String? {
        let header = Array(data.prefix(64))
        func text(_ start: Int, _ count: Int) -> String {
            guard header.count >= start + count else { return "" }
            return String(bytes: header[start..<(start + count)], encoding: .ascii) ?? ""
        }
        if text(0, 4) == "RIFF", text(8, 4) == "WAVE" { return "wav" }
        if text(0, 4) == "FORM", ["AIFF", "AIFC"].contains(text(8, 4)) { return "aiff" }
        if text(0, 4) == "caff" { return "caf" }
        if text(0, 4) == "fLaC" { return "flac" }
        if text(0, 4) == "OggS" { return "ogg" }
        if text(4, 4) == "ftyp" {
            if text(8, 4) == "qt  " { return "mov" }
            return kind == "audio" ? "m4a" : "mp4"
        }
        if text(0, 3) == "ID3" || (header.count > 1 && header[0] == 0xff && header[1] & 0xe0 == 0xe0) { return "mp3" }
        if header.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) {
            let bytes = String(decoding: data.prefix(4_096), as: UTF8.self)
            return bytes.contains("webm") ? "webm" : "mkv"
        }
        return nil
    }
}
