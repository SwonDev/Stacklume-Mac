import Foundation

/// Espera de proveedor compartida por host. Sin cabecera válida se espera un minuto;
/// se limita a 24 horas y 256 hosts para acotar estado y cabeceras no confiables.
struct HTTPRateLimitState: Sendable {
    static let maximumHosts = 256
    static let maximumWait: TimeInterval = 24 * 60 * 60
    static let fallbackWait: TimeInterval = 60
    private(set) var deadlines: [String: Date] = [:]

    static func waitDuration(retryAfter: String?, now: Date) -> TimeInterval {
        guard let raw = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return fallbackWait }
        if raw.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return min(seconds, maximumWait)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let deadline = formatter.date(from: raw) {
                return min(max(0, deadline.timeIntervalSince(now)), maximumWait)
            }
        }
        return fallbackWait
    }

    mutating func record(host: String, retryAfter: String?, now: Date) {
        deadlines = deadlines.filter { $0.value > now }
        let host = host.lowercased()
        if deadlines[host] == nil, deadlines.count >= Self.maximumHosts,
           let earliest = deadlines.min(by: { $0.value < $1.value })?.key {
            deadlines[earliest] = nil
        }
        let deadline = now.addingTimeInterval(Self.waitDuration(retryAfter: retryAfter, now: now))
        deadlines[host] = max(deadlines[host] ?? now, deadline)
    }

    mutating func isCoolingDown(host: String, now: Date) -> Bool {
        let host = host.lowercased()
        guard let deadline = deadlines[host] else { return false }
        guard deadline > now else { deadlines[host] = nil; return false }
        return true
    }
}
