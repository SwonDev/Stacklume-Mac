import Foundation

/// Registro QA acotado, sin Observation ni invalidaciones de layout.
@MainActor final class StacklumeFontMeasurements {
    private var readings: [[String: Any]] = []
    private var seen: Set<String> = []
    private let limit = 512
    func clear() { readings.removeAll(keepingCapacity: true); seen.removeAll(keepingCapacity: true) }
    func record(file: String, line: Int, factor: Double, base: Double, actual: Double, bold: Bool) {
        guard readings.count < limit else { return }
        let key = "\(file):\(line):\(factor):\(base):\(actual):\(bold)"
        guard seen.insert(key).inserted else { return }
        readings.append(["source": file, "line": line, "factor": factor, "basePoints": base,
                         "actualPoints": actual, "isBold": bold])
    }
    var reachedLimit: Bool { readings.count >= limit }
    var snapshot: [[String: Any]] { readings }
}
