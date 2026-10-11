import Foundation

enum BoundedFileReadError: LocalizedError, Equatable {
    case invalidLimit
    case notRegularFile
    case tooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "El límite de lectura no es válido."
        case .notRegularFile:
            "El elemento seleccionado no es un archivo normal."
        case .tooLarge(let maximumBytes):
            "El archivo supera el límite permitido de \(maximumBytes) bytes."
        }
    }
}

/// Lee archivos no confiables sin depender de que `fileSize` esté disponible y sin
/// materializar el contenido completo antes de comprobar la cota.
enum BoundedFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else { throw BoundedFileReadError.invalidLimit }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw BoundedFileReadError.notRegularFile }
        if let size = values.fileSize, size > maximumBytes {
            throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        result.reserveCapacity(min(values.fileSize ?? 64 * 1_024, maximumBytes))
        let chunkSize = 256 * 1_024

        while true {
            let remaining = maximumBytes - result.count
            guard remaining >= 0 else {
                throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
            }
            let requested = remaining >= chunkSize ? chunkSize : remaining + 1
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else {
                throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
            }
            result.append(chunk)
        }
        return result
    }
}
