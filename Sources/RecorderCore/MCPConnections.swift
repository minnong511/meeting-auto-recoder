import Darwin
import Foundation

/// Short-lived local presence records contain only the MCP client's name.
/// A held file lock distinguishes live sessions from stale files after a crash.
public struct MCPClientConnection: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
}

public final class MCPConnectionLease {
    private let descriptor: Int32
    private let path: String

    public init(name: String?, version: String?) throws {
        let directory = try MCPConnectionRegistry.directory()
        let id = UUID().uuidString
        let pending = directory.appendingPathComponent(".pending-" + id).path
        let final = directory.appendingPathComponent(id + ".json").path
        let fd = Darwin.open(pending, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MCPConnectionRegistry.posixError() }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MCPConnectionRegistry.posixError() }
            let record = MCPClientConnection(id: id, name: MCPConnectionRegistry.clean(name) ?? "이름 없는 클라이언트",
                                             version: MCPConnectionRegistry.clean(version))
            let data = try JSONEncoder().encode(record)
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
            guard Darwin.rename(pending, final) == 0 else { throw MCPConnectionRegistry.posixError() }
        } catch {
            Darwin.close(fd)
            Darwin.unlink(pending)
            throw error
        }
        descriptor = fd
        path = final
    }

    deinit {
        Darwin.unlink(path)
        Darwin.close(descriptor)
    }
}

public enum MCPConnectionRegistry {
    static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = String(value.filter { $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }.prefix(60))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("meeting-recorder-mcp-\(getuid())", isDirectory: true)
        if mkdir(url.path, S_IRWXU) != 0 && errno != EEXIST { throw posixError() }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        return url
    }

    public static func activeClients() throws -> [MCPClientConnection] {
        let directory = try directory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        func readClient(_ url: URL) throws -> MCPClientConnection? {
            let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            if fd < 0 {
                if errno == ENOENT { return nil }
                throw posixError()
            }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw posixError() }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 4096 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // The process exited without removing its record. Its lock is no longer held.
                Darwin.unlink(url.path)
                flock(fd, LOCK_UN)
                return nil
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw posixError() }
            let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
            return try JSONDecoder().decode(MCPClientConnection.self, from: data)
        }
        return try urls.filter { $0.pathExtension == "json" }.compactMap(readClient)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
