import Foundation
import Darwin

/// Opt-in del ensayo de interfaz. La ruta normal no abre archivos ni consulta preferencias.
enum NativeUIQAConfiguration {
    struct Scope: Sendable {
        let root: URL
        fileprivate let nonce: String
    }
    enum Failure: String, Error {
        case incompleteOptIn, incompatibleMode, invalidRoot, unsafePath, invalidMarker
        case invalidCanonicalBundle, reportUnavailable, invalidScrollObservation
    }
    static let flag = "--stacklume-native-ui-qa"
    static let rootKey = "STACKLUME_NATIVE_UI_QA_ROOT"
    static let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StacklumeDevelopment/native-isolation/ui-runs").path
    private struct Marker: Decodable {
        let format: Int
        let purpose: String
        let root: String
        let ownerUID: UInt32
        let nonce: String
    }

    static func parse(environment: [String: String], arguments: [String]) throws -> Scope? {
        let flags = arguments.filter { $0.hasPrefix(flag) }
        let raw = environment[rootKey]
        guard raw != nil || !flags.isEmpty else { return nil }
        guard let raw, flags == [flag] else { throw Failure.incompleteOptIn }
        guard arguments.dropFirst().elementsEqual([flag]),
              environment["STACKLUME_QA_HOME"] == nil,
              !environment.keys.contains(where: { $0.hasPrefix("STACKLUME_") && ($0.contains("LFM") || $0.contains("AUDIT") || $0.contains("DIAGNOSTIC")) }),
              !environment.keys.contains(where: { $0.contains("MARKETING_DEMO") }),
              !arguments.contains(where: {
                  $0 != flag && ($0.hasPrefix("--stacklume-") || $0 == "--descriptor-sha256" || $0.contains("marketing-demo"))
              }) else { throw Failure.incompatibleMode }
        let root = try validateRoot(raw)
        let scope = Scope(root: root, nonce: try marker(root).nonce)
        _ = try scrollEnvironment(scope, environment: environment)
        return scope
    }

    /// Solo chat, salida directa bajo el scope validado; no acepta otros parámetros de observación.
    static func scrollEnvironment(_ scope: Scope, environment: [String: String]) throws -> [String: String]? {
        let keys = Set(environment.keys.filter { $0.hasPrefix("STACKLUME_SCROLL_") })
        guard !keys.isEmpty else { return nil }
        let allowed: Set<String> = ["STACKLUME_SCROLL_OBSERVATION", "STACKLUME_SCROLL_SURFACES", "STACKLUME_SCROLL_OUTPUT"]
        guard keys == allowed, environment["STACKLUME_SCROLL_OBSERVATION"] == "1",
              environment["STACKLUME_SCROLL_SURFACES"] == "chat" else { throw Failure.invalidScrollObservation }
        let root = try validateRoot(scope.root.path)
        guard try marker(root).nonce == scope.nonce,
              environment["STACKLUME_SCROLL_OUTPUT"] == root.appendingPathComponent("scroll-chat.jsonl").path else {
            throw Failure.invalidScrollObservation
        }
        return Dictionary(uniqueKeysWithValues: allowed.map { ($0, environment[$0]!) })
    }

    static func requireCanonicalBundle() throws {
        guard Bundle.main.bundleIdentifier == "com.swondev.stacklume",
              Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Stacklume.app",
              Bundle.main.executableURL?.deletingLastPathComponent().path == "/Applications/Stacklume.app/Contents/MacOS"
        else { throw Failure.invalidCanonicalBundle }
    }

    static func writeReport(_ scope: Scope, phase: String, values: [String: Any] = [:]) throws {
        guard ["before", "ready", "result", "closed"].contains(phase) else { throw Failure.reportUnavailable }
        let root = try validateRoot(scope.root.path)
        guard try marker(root).nonce == scope.nonce else { throw Failure.invalidMarker }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.reportUnavailable }
        defer { close(directory) }
        var report = values
        report["format"] = 1
        report["phase"] = phase
        report["pid"] = getpid()
        report["uptime"] = ProcessInfo.processInfo.systemUptime
        report["root"] = root.path
        report["bundleID"] = Bundle.main.bundleIdentifier ?? ""
        report["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        report["systemServicesIsolated"] = false
        report["allWritesPrivate"] = false
        report["releaseCertified"] = false
        var data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        data.append(0x0a)
        let descriptor = openat(directory, "native-ui-qa-\(phase).json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                                S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.reportUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw Failure.reportUnavailable }
        } catch { throw Failure.reportUnavailable }
    }

    static func stop(_ error: Error) -> Never {
        let reason = (error as? Failure)?.rawValue ?? "qaFailure"
        FileHandle.standardError.write(Data("Ensayo nativo bloqueado: \(reason)\n".utf8))
        _exit(78)
    }

    private static func validateRoot(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/"), !raw.contains("\0"),
              !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.invalidRoot }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        let name = root.lastPathComponent
        guard root.deletingLastPathComponent().path == base, name.hasPrefix("run-"),
              let uuid = UUID(uuidString: String(name.dropFirst(4))),
              name == "run-" + uuid.uuidString.lowercased() else { throw Failure.invalidRoot }
        var prefix = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            prefix.appendPathComponent(component)
            var info = stat()
            guard lstat(prefix.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw Failure.unsafePath }
        }
        var baseInfo = stat()
        guard lstat(base, &baseInfo) == 0, baseInfo.st_uid == getuid(),
              baseInfo.st_mode & S_IFMT == S_IFDIR, baseInfo.st_mode & 0o777 == 0o700 else { throw Failure.invalidRoot }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { throw Failure.invalidRoot }
        return root
    }

    private static func marker(_ root: URL) throws -> Marker {
        let descriptor = open(root.appendingPathComponent(".stacklume-native-ui-qa.json").path,
                              O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalidMarker }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096,
              let data = try handle.read(upToCount: 4097), data.count <= 4096,
              let value = try? JSONDecoder().decode(Marker.self, from: data),
              value.format == 1, value.purpose == "Stacklume native UI QA", value.root == root.path,
              value.ownerUID == getuid(), value.nonce.count == 64,
              value.nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidMarker
        }
        return value
    }
}
