import Foundation
import CryptoKit
import Darwin

struct CanonicalProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let start_abstime: UInt64
    let executablePath: String
}
struct CanonicalInstalledIdentity: Codable, Equatable, Sendable {
    let executablePath: String
    let executableSHA256: String
    let bundleIdentifier: String
    let bundleVersion: String
}
struct CanonicalLaunchDescriptor: Codable, Equatable, Sendable {
    let version: Int
    let operation: String
    let run_id: String
    let executablePath: String
    let executableSHA256: String
    let bundleIdentifier: String
    let bundleVersion: String
    let sourceSHA256: String
    let candidatesSHA256: String
    let contextSHA256: String
}
struct CanonicalLaunchGrant: Codable, Equatable, Sendable {
    let deadline_uptime_nanoseconds: UInt64
    let version: Int
    let run_id: String
    let descriptorSHA256: String
    let pid: Int32
    let start_abstime: UInt64
}
struct CanonicalPhaseRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let run_id: String
    let phase: String
    let sequence: Int
}
struct CanonicalAcknowledgement: Codable, Equatable, Sendable {
    let pid: Int32
    let run_id: String
    let approved: Bool
}
struct CanonicalClaim: Codable, Equatable, Sendable {
    let pid: Int32
    let run_id: String
    let descriptorSHA256: String
    let consumed: Bool
}

enum CanonicalTicketError: Error {
    case arguments, directory, ownership, size, malformed, identity, descriptor, grant, acknowledgement, existing, changed
}
enum CanonicalNativeIdentity {
    static func current() throws -> CanonicalProcessIdentity { try read(pid: getpid()) }
    static func read(pid: Int32) throws -> CanonicalProcessIdentity {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result == 0, info.ri_proc_start_abstime > 0, length > 0 else { throw CanonicalTicketError.identity }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return .init(pid: pid, start_abstime: info.ri_proc_start_abstime, executablePath: path)
    }
}

// La igualdad con la serialización canónica rechaza claves repetidas, tipos
// alternativos y registros extras; este parser es sólo del ticket, no del LFM.
enum CanonicalWire {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func decoded<T: Codable>(_ type: T.Type, data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data),
              try encoded(value) == data else { throw CanonicalTicketError.malformed }
        return value
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

final class CanonicalEphemeralFiles {
    let directory: URL
    private var owned: [String: Data] = [:]
    static let names: Set<String> = ["descriptor.json", "grant.json", "phase.json", "ack.json", "claim.json", "outcome.json", "trace.json"]
    init(directory: URL, allowedRoot: URL, runID: String) throws {
        guard directory.isFileURL, allowedRoot.isFileURL, let nonce = UUID(uuidString: runID), nonce.uuidString == runID,
              directory.standardizedFileURL.path == allowedRoot.standardizedFileURL.appendingPathComponent(runID).path,
              directory.resolvingSymlinksInPath().path == directory.path,
              allowedRoot.resolvingSymlinksInPath().path == allowedRoot.path else { throw CanonicalTicketError.directory }
        self.directory = directory
        for url in [allowedRoot, directory] {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw CanonicalTicketError.directory }
        }
    }
    func read(_ name: String, maximum: Int) throws -> Data {
        guard Self.names.contains(name), maximum > 0, maximum <= 8_192 else { throw CanonicalTicketError.ownership }
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw CanonicalTicketError.ownership }
        guard info.st_size > 0, info.st_size <= maximum else { throw CanonicalTicketError.size }
        var bytes = [UInt8](repeating: 0, count: maximum + 1)
        var total = 0
        let capacity = bytes.count
        while total < capacity {
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: total), capacity - total) }
            if amount < 0 { if errno == EINTR { continue }; throw CanonicalTicketError.ownership }
            if amount == 0 { break }; total += amount
        }
        guard total == info.st_size, total <= maximum else { throw CanonicalTicketError.size }
        return Data(bytes.prefix(total))
    }
    func create<T: Encodable>(_ value: T, name: String, maximum: Int) throws {
        guard Self.names.contains(name), owned[name] == nil else { throw CanonicalTicketError.existing }
        let data = try CanonicalWire.encoded(value)
        guard !data.isEmpty, data.count <= maximum, maximum <= 8_192 else { throw CanonicalTicketError.size }
        let temporary = directory.appendingPathComponent(".new-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CanonicalTicketError.ownership }
        defer { close(fd); unlink(temporary.path) }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0, link(temporary.path, directory.appendingPathComponent(name).path) == 0 else { throw CanonicalTicketError.existing }
        owned[name] = data
    }
    func update<T: Encodable>(_ value: T, name: String, maximum: Int) throws {
        guard let prior = owned[name], try read(name, maximum: maximum) == prior else { throw CanonicalTicketError.changed }
        let data = try CanonicalWire.encoded(value)
        guard !data.isEmpty, data.count <= maximum else { throw CanonicalTicketError.size }
        let temporary = directory.appendingPathComponent(".new-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CanonicalTicketError.ownership }
        defer { close(fd); unlink(temporary.path) }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0, rename(temporary.path, directory.appendingPathComponent(name).path) == 0 else { throw CanonicalTicketError.ownership }
        owned[name] = data
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var total = 0
            while total < bytes.count {
                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: total), bytes.count - total)
                if amount <= 0 { if amount < 0 && errno == EINTR { continue }; throw CanonicalTicketError.ownership }
                total += amount
            }
        }
    }
}

final class CanonicalArmedTicket {
    let descriptor: CanonicalLaunchDescriptor
    let descriptorSHA256: String
    let identity: CanonicalProcessIdentity
    let files: CanonicalEphemeralFiles
    private var acceptedGrant: CanonicalLaunchGrant?
    init(descriptor: CanonicalLaunchDescriptor, descriptorSHA256: String, identity: CanonicalProcessIdentity, files: CanonicalEphemeralFiles) {
        self.descriptor = descriptor; self.descriptorSHA256 = descriptorSHA256
        self.identity = identity; self.files = files
    }
    static let executable = "/Applications/Stacklume.app/Contents/MacOS/Stacklume"
    static func prepare(arguments: [String], allowedRoot: URL, installed: CanonicalInstalledIdentity,
                        identity: CanonicalProcessIdentity) throws -> CanonicalArmedTicket? {
        guard arguments.contains("--stacklume-x91-diagnostic") || arguments.contains("--descriptor-sha256") else { return nil }
        guard arguments.count == 4, arguments[0] == "--stacklume-x91-diagnostic", arguments[2] == "--descriptor-sha256",
              CanonicalWire.validHash(arguments[3]) else { throw CanonicalTicketError.arguments }
        let descriptorURL = URL(fileURLWithPath: arguments[1])
        guard arguments[1].hasPrefix("/"), descriptorURL.lastPathComponent == "descriptor.json" else { throw CanonicalTicketError.arguments }
        let runID = descriptorURL.deletingLastPathComponent().lastPathComponent
        let files = try CanonicalEphemeralFiles(directory: descriptorURL.deletingLastPathComponent(), allowedRoot: allowedRoot, runID: runID)
        let data = try files.read("descriptor.json", maximum: 4_096)
        guard CanonicalWire.hash(data) == arguments[3] else { throw CanonicalTicketError.descriptor }
        let descriptor = try CanonicalWire.decoded(CanonicalLaunchDescriptor.self, data: data)
        guard descriptor.version == 1, descriptor.operation == "x91-semantic-audit", descriptor.run_id == runID,
              descriptor.executablePath == Self.executable, identity.executablePath == Self.executable,
              installed.executablePath == Self.executable, descriptor.executableSHA256 == installed.executableSHA256,
              CanonicalWire.validHash(descriptor.executableSHA256), descriptor.bundleIdentifier == installed.bundleIdentifier,
              !descriptor.bundleIdentifier.isEmpty, descriptor.bundleVersion == installed.bundleVersion, !descriptor.bundleVersion.isEmpty,
              descriptor.sourceSHA256 == CanonicalAuditFixture.sourceSHA256,
              descriptor.candidatesSHA256 == CanonicalAuditFixture.candidatesSHA256,
              descriptor.contextSHA256 == CanonicalAuditFixture.contextSHA256 else { throw CanonicalTicketError.descriptor }
        return .init(descriptor: descriptor, descriptorSHA256: arguments[3], identity: identity, files: files)
    }
    func validateGrant(current: CanonicalProcessIdentity) throws {
        guard current == identity else { throw CanonicalTicketError.identity }
        let grant = try CanonicalWire.decoded(CanonicalLaunchGrant.self, data: files.read("grant.json", maximum: 2_048))
        guard grant.version == 1, grant.run_id == descriptor.run_id, grant.descriptorSHA256 == descriptorSHA256,
              grant.pid == current.pid, grant.start_abstime == current.start_abstime else { throw CanonicalTicketError.grant }
        let now = DispatchTime.now().uptimeNanoseconds
        guard grant.deadline_uptime_nanoseconds > now, grant.deadline_uptime_nanoseconds - now <= 360_000_000_000,
              acceptedGrant == nil || acceptedGrant == grant else { throw CanonicalTicketError.grant }
        acceptedGrant = grant
    }
    func revalidate(current: CanonicalProcessIdentity, installed: CanonicalInstalledIdentity) throws {
        let original = try files.read("descriptor.json", maximum: 4_096)
        guard CanonicalWire.hash(original) == descriptorSHA256,
              try CanonicalWire.decoded(CanonicalLaunchDescriptor.self, data: original) == descriptor,
              installed.executablePath == descriptor.executablePath, installed.executableSHA256 == descriptor.executableSHA256,
              installed.bundleIdentifier == descriptor.bundleIdentifier, installed.bundleVersion == descriptor.bundleVersion else { throw CanonicalTicketError.changed }
        try validateGrant(current: current)
        let ack = try CanonicalWire.decoded(CanonicalAcknowledgement.self, data: files.read("ack.json", maximum: 2_048))
        guard ack.pid == identity.pid, ack.run_id == descriptor.run_id, ack.approved else { throw CanonicalTicketError.acknowledgement }
    }
}
