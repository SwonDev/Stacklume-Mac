import Foundation
import SwiftData
import StacklumeCore
import OSLog
import Darwin

/// Comprueba una raíz de QA preparada por el operador. No redirige preferencias ni servicios del sistema.
@MainActor
enum CanonicalQAIsolation {
    struct Scope {
        let root: URL
        fileprivate let nonce: String
        fileprivate let stores: [String]
    }

    enum Failure: String, Error {
        case invalidRoot, unsafePath, invalidMarker, fixedHomeMismatch, foundationHomeMismatch
        case supportOutsideRoot, storeOutsideRoot, preferenceFileInvalid, preferenceSentinelMismatch
        case preferenceArgumentOverride, invalidBundle, containerConfigurationMismatch, reportUnavailable
    }

    private struct Marker: Decodable {
        let format: Int
        let purpose: String
        let root: String
        let ownerUID: UInt32
        let nonce: String
    }

    private struct Report: Encodable {
        var phase: String
        var status: String
        var failure: String?
        let pid = getpid()
        var bundleID: String
        var version: String
        var build: String
        var root: String
        var foundationHome: String
        var nsHome: String
        var applicationSupport: String
        var preferencesFile: String
        var storeConfigurations: [String]
        var temporary: String
        var temporaryInsideRoot: Bool
        var preferencesSentinelConfirmed: Bool
        let systemServicesIsolated = false
        let keychainIsolated = false
        let allWritesPrivate = false
        let runtimeGUIAuthorized = false
    }

    private static let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StacklumeDevelopment/native-isolation").path
    private static let markerName = ".stacklume-qa-home.json"
    private static let sentinelKey = "STACKLUME_QA_SENTINEL"
    private static let logger = Logger(subsystem: "com.swondev.stacklume", category: "CanonicalQAIsolation")

    static func requireBeforeStartup(environment: [String: String], arguments: [String]) -> Scope? {
        do { return try beforeStartup(environment: environment, arguments: arguments) }
        catch { stop(error) }
    }

    static func beforeStartup(environment: [String: String], arguments: [String]) throws -> Scope? {
        guard let rawRoot = environment["STACKLUME_QA_HOME"] else { return nil }
        let root = try validateRoot(rawRoot)
        let marker = try readMarker(root)
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "com.swondev.stacklume" else { throw Failure.invalidBundle }
        let preferences = root.appendingPathComponent("Library/Preferences/com.swondev.stacklume.plist")
        var report = Report(phase: "beforeStartup", status: "blocked", bundleID: bundle.bundleIdentifier ?? "",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", root: root.path,
            foundationHome: "", nsHome: "", applicationSupport: "", preferencesFile: preferences.path,
            storeConfigurations: [], temporary: "", temporaryInsideRoot: false, preferencesSentinelConfirmed: false)
        do {
            guard let fixed = environment["CFFIXED_USER_HOME"], try canonicalPath(fixed).path == root.path else {
                throw Failure.fixedHomeMismatch
            }
            report.foundationHome = FileManager.default.homeDirectoryForCurrentUser.path
            report.nsHome = NSHomeDirectory()
            guard report.foundationHome == root.path, report.nsHome == root.path else {
                throw Failure.foundationHomeMismatch
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            report.applicationSupport = support.path
            guard inside(support, root: root) else { throw Failure.supportOutsideRoot }
            try rejectSymlinks(support)
            // Es la configuración persistente de PersistenceController en macOS; no crea un contenedor.
            let configurations = [ModelConfiguration(schema: Schema(StacklumeCore.models))]
            report.storeConfigurations = configurations.map(\.url.path).sorted()
            try verifyStorePaths(report.storeConfigurations, root: root)
            report.temporary = NSTemporaryDirectory()
            report.temporaryInsideRoot = inside(URL(fileURLWithPath: report.temporary), root: root)
            guard !arguments.contains(where: { $0.drop(while: { $0 == "-" }).hasPrefix(sentinelKey) }) else {
                throw Failure.preferenceArgumentOverride
            }
            try validateRegularFile(preferences, mode: 0o600)
            guard UserDefaults.standard.string(forKey: sentinelKey) == marker.nonce else {
                throw Failure.preferenceSentinelMismatch
            }
            report.preferencesSentinelConfirmed = true
            report.status = "localBoundariesVerified"
            try write(report, root: root, filename: "qa-isolation-before.json")
            return Scope(root: root, nonce: marker.nonce, stores: report.storeConfigurations)
        } catch {
            report.failure = (error as? Failure)?.rawValue ?? "foundationFailure"
            try write(report, root: root, filename: "qa-isolation-before.json")
            throw error
        }
    }

    static func requireAfterContainer(_ scope: Scope?, container: ModelContainer) {
        guard let scope else { return }
        do { try afterContainer(scope, container: container) }
        catch { stop(error) }
    }

    static func afterContainer(_ scope: Scope, container: ModelContainer) throws {
        let root = try validateRoot(scope.root.path)
        let marker = try readMarker(root)
        guard marker.nonce == scope.nonce else { throw Failure.invalidMarker }
        let paths = container.configurations.map(\.url.path).sorted()
        var report = Report(phase: "afterContainer", status: "blocked", bundleID: Bundle.main.bundleIdentifier ?? "",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", root: root.path,
            foundationHome: FileManager.default.homeDirectoryForCurrentUser.path, nsHome: NSHomeDirectory(),
            applicationSupport: "",
            preferencesFile: root.appendingPathComponent("Library/Preferences/com.swondev.stacklume.plist").path,
            storeConfigurations: paths, temporary: NSTemporaryDirectory(),
            temporaryInsideRoot: inside(URL(fileURLWithPath: NSTemporaryDirectory()), root: root),
            preferencesSentinelConfirmed: false)
        do {
            try verifyStorePaths(paths, root: root)
            guard paths == scope.stores else { throw Failure.containerConfigurationMismatch }
            guard report.foundationHome == root.path, report.nsHome == root.path else {
                throw Failure.foundationHomeMismatch
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            report.applicationSupport = support.path
            guard inside(support, root: root) else { throw Failure.supportOutsideRoot }
            try rejectSymlinks(support)
            try validateRegularFile(URL(fileURLWithPath: report.preferencesFile), mode: 0o600)
            guard UserDefaults.standard.string(forKey: sentinelKey) == marker.nonce else {
                throw Failure.preferenceSentinelMismatch
            }
            report.preferencesSentinelConfirmed = true
            report.status = "localBoundariesVerified"
            try write(report, root: root, filename: "qa-isolation-after.json")
        } catch {
            report.failure = (error as? Failure)?.rawValue ?? "foundationFailure"
            try write(report, root: root, filename: "qa-isolation-after.json")
            throw error
        }
    }

    private static func canonicalPath(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/"), !raw.contains("\0"),
              !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw Failure.invalidRoot
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    private static func validateRoot(_ raw: String) throws -> URL {
        let root = try canonicalPath(raw)
        let name = root.lastPathComponent
        guard root.deletingLastPathComponent().path == base, name.hasPrefix("home-"),
              let uuid = UUID(uuidString: String(name.dropFirst(5))),
              name == "home-" + uuid.uuidString.lowercased() else { throw Failure.invalidRoot }
        try rejectSymlinks(root)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw Failure.invalidRoot
        }
        return root
    }

    private static func readMarker(_ root: URL) throws -> Marker {
        let path = root.appendingPathComponent(markerName)
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalidMarker }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= 4096,
              let data = try handle.read(upToCount: 4097), data.count <= 4096,
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.format == 1, marker.purpose == "Stacklume canonical QA", marker.root == root.path,
              marker.ownerUID == getuid(), marker.nonce.count == 64,
              marker.nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidMarker
        }
        return marker
    }

    private static func inside(_ url: URL, root: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    private static func rejectSymlinks(_ url: URL) throws {
        var prefix = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            prefix.appendPathComponent(component)
            var info = stat()
            if lstat(prefix.path, &info) != 0 {
                guard errno == ENOENT else { throw Failure.unsafePath }
                return
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw Failure.unsafePath }
        }
    }

    private static func validateRegularFile(_ path: URL, mode: mode_t) throws {
        try rejectSymlinks(path)
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == mode else { throw Failure.preferenceFileInvalid }
    }

    private static func verifyStorePaths(_ paths: [String], root: URL) throws {
        guard !paths.isEmpty else { throw Failure.storeOutsideRoot }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard inside(url, root: root) else { throw Failure.storeOutsideRoot }
            for suffix in ["", "-wal", "-shm"] {
                let candidate = URL(fileURLWithPath: path + suffix)
                try rejectSymlinks(candidate)
                var info = stat()
                if lstat(candidate.path, &info) == 0 {
                    guard info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG else {
                        throw Failure.unsafePath
                    }
                } else if errno != ENOENT {
                    throw Failure.unsafePath
                }
            }
        }
    }

    private static func write(_ report: Report, root: URL, filename: String) throws {
        _ = try validateRoot(root.path)
        let descriptor = open(root.appendingPathComponent(filename).path,
                              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.reportUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            var data = try JSONEncoder().encode(report)
            data.append(0x0a)
            try handle.write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw Failure.reportUnavailable }
        } catch { throw Failure.reportUnavailable }
    }

    private static func stop(_ error: Error) -> Never {
        let code = (error as? Failure)?.rawValue ?? "foundationFailure"
        logger.error("Arranque de QA bloqueado: \(code, privacy: .public)")
        _exit(78)
    }
}
