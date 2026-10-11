import Foundation
import Darwin

enum ExternalHTTPError: LocalizedError, Equatable {
    case invalidLimit
    case unsafeURL
    case invalidResponse
    case unacceptableStatus(Int)
    case unsupportedContent
    case tooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "El límite de descarga no es válido."
        case .unsafeURL:
            "La URL apunta a un destino local, privado o no permitido."
        case .invalidResponse:
            "El servidor no devolvió una respuesta HTTP válida."
        case .unacceptableStatus(let status):
            "El servidor respondió con el estado HTTP \(status)."
        case .unsupportedContent:
            "El servidor devolvió un tipo de contenido no permitido."
        case .tooLarge(let maximumBytes):
            "La respuesta supera el límite seguro de \(maximumBytes) bytes."
        }
    }
}

struct ExternalHTTPResponse: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// Cliente único para adquisiciones automáticas desde Internet. No usa cookies,
/// credenciales ni caché; valida destino inicial y redirecciones, resuelve DNS y
/// consume el cuerpo como stream con una cota real.
actor ExternalHTTPClient {
    static let shared = ExternalHTTPClient()

    private let session: URLSession
    private let rateLimits: ExternalHTTPRateLimitGate

    private init() {
        let gate = ExternalHTTPRateLimitGate()
        rateLimits = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(
            configuration: configuration,
            delegate: ExternalHTTPRedirectDelegate(rateLimits: gate),
            delegateQueue: nil
        )
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int,
        acceptedStatusCodes: ClosedRange<Int> = 200...299,
        allowedMIMEPrefixes: [String] = [],
        enforceContentLength: Bool = true
    ) async throws -> ExternalHTTPResponse {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw ExternalHTTPError.invalidLimit }
        guard let url = request.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
              let host = url.host(),
              await Self.hasOnlyPublicAddresses(host)
        else {
            throw ExternalHTTPError.unsafeURL
        }

        try Task.checkCancellation()
        guard await !rateLimits.isCoolingDown(host: host) else {
            throw ExternalHTTPError.unacceptableStatus(429)
        }
        try Task.checkCancellation()
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              let finalURL = response.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(finalURL)
        else {
            throw ExternalHTTPError.invalidResponse
        }
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            let now = Date()
            await rateLimits.record(host: host, retryAfter: retryAfter, now: now)
            if let finalHost = response.url?.host(), finalHost != host {
                await rateLimits.record(host: finalHost, retryAfter: retryAfter, now: now)
            }
            throw ExternalHTTPError.unacceptableStatus(429)
        }
        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw ExternalHTTPError.unacceptableStatus(response.statusCode)
        }

        if enforceContentLength,
           let rawLength = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(rawLength), length > maximumBytes {
            throw ExternalHTTPError.tooLarge(maximumBytes: maximumBytes)
        }
        if !allowedMIMEPrefixes.isEmpty {
            let mime = (response.mimeType ?? "").lowercased()
            guard allowedMIMEPrefixes.contains(where: mime.hasPrefix) else {
                throw ExternalHTTPError.unsupportedContent
            }
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 256 * 1_024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw ExternalHTTPError.tooLarge(maximumBytes: maximumBytes)
            }
            data.append(byte)
        }
        return ExternalHTTPResponse(data: data, response: response)
    }

    /// Obtiene solo cabeceras y URL final. Se usa para resolver acortadores o comprobar
    /// existencia sin descargar accidentalmente un archivo de tamaño arbitrario.
    func response(
        for request: URLRequest,
        acceptedStatusCodes: ClosedRange<Int> = 200...399
    ) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        guard let url = request.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
              let host = url.host(),
              await Self.hasOnlyPublicAddresses(host)
        else {
            throw ExternalHTTPError.unsafeURL
        }
        try Task.checkCancellation()
        guard await !rateLimits.isCoolingDown(host: host) else {
            throw ExternalHTTPError.unacceptableStatus(429)
        }
        try Task.checkCancellation()
        let (_, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              let finalURL = response.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(finalURL)
        else {
            throw ExternalHTTPError.invalidResponse
        }
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            let now = Date()
            await rateLimits.record(host: host, retryAfter: retryAfter, now: now)
            if let finalHost = response.url?.host(), finalHost != host {
                await rateLimits.record(host: finalHost, retryAfter: retryAfter, now: now)
            }
            throw ExternalHTTPError.unacceptableStatus(429)
        }
        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw ExternalHTTPError.unacceptableStatus(response.statusCode)
        }
        return response
    }

    private static func hasOnlyPublicAddresses(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            AssistantHostResolver.hasOnlyPublicAddresses(host)
        }.value
    }
}

private actor ExternalHTTPRateLimitGate {
    private var state = HTTPRateLimitState()

    func isCoolingDown(host: String) -> Bool {
        state.isCoolingDown(host: host, now: Date())
    }

    func record(host: String, retryAfter: String?, now: Date) {
        state.record(host: host, retryAfter: retryAfter, now: now)
    }
}

private final class ExternalHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let rateLimits: ExternalHTTPRateLimitGate

    init(rateLimits: ExternalHTTPRateLimitGate) {
        self.rateLimits = rateLimits
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(destination),
              destination.host().map(AssistantHostResolver.hasOnlyPublicAddresses) == true
        else {
            completionHandler(nil)
            return
        }

        let previousScheme = task.currentRequest?.url?.scheme?.lowercased()
        let nextScheme = destination.scheme?.lowercased()
        if previousScheme == "https", nextScheme != "https" {
            completionHandler(nil)
            return
        }
        var safeRequest = request
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        let validatedRequest = safeRequest
        Task {
            guard task.state != .canceling, task.state != .completed,
                  let host = destination.host(),
                  await !rateLimits.isCoolingDown(host: host) else {
                completionHandler(nil)
                return
            }
            guard task.state != .canceling, task.state != .completed else {
                completionHandler(nil)
                return
            }
            completionHandler(validatedRequest)
        }
    }
}

/// Segunda defensa SSRF: resuelve DNS y rechaza el destino si CUALQUIER dirección
/// obtenida pertenece a loopback, redes privadas, link-local o rangos reservados.
enum AssistantHostResolver {
    static func hasOnlyPublicAddresses(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let first else { return false }
        defer { freeaddrinfo(first) }

        var foundAddress = false
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let pointer = current {
            defer { current = pointer.pointee.ai_next }
            guard let address = pointer.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                pointer.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { return false }
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let numeric = String(
                decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard isPublicNumericAddress(numeric) else { return false }
            foundAddress = true
        }
        return foundAddress
    }

    static func isPublicNumericAddress(_ raw: String) -> Bool {
        let address = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }

        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: &ipv4) { isPublicIPv4(Array($0)) }
        }

        var ipv6 = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: &ipv6) { rawBytes in
            let bytes = Array(rawBytes)
            guard bytes.count == 16 else { return false }

            // IPv4 mapeada: también cubre la forma hexadecimal `::ffff:7f00:1`.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPublicIPv4(Array(bytes[12...15]))
            }

            // Solo global unicast 2000::/3. Excluye loopback, unspecified, ULA,
            // link-local, multicast, NAT64 y demás rangos especiales por construcción.
            guard bytes[0] & 0xE0 == 0x20 else { return false }
            // Documentación, benchmarking y mecanismos de transición obsoletos.
            if bytes[0...3].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false }
            if bytes[0...5].elementsEqual([0x20, 0x01, 0x00, 0x02, 0x00, 0x00]) { return false }
            if bytes[0...3].elementsEqual([0x20, 0x01, 0x00, 0x00]) { return false }
            if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
            if bytes[0] == 0x3F, bytes[1] == 0xFE { return false }
            return true
        }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 0 || b == 168) { return false }
        if a == 192 && b == 88 && c == 99 { return false }
        if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }
}
