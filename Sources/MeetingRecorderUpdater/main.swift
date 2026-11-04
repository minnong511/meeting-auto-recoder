import CryptoKit
import Darwin
import Foundation
import RecorderCore
import Security

private struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let fm = FileManager.default
private let limit = 256 * 1024 * 1024
private let bundleID = "dev.meetingrecorder.prototype"

private func command(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> (Int32, Data) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardOutput = capture ? pipe.fileHandleForWriting : FileHandle.nullDevice
    try p.run()
    try pipe.fileHandleForWriting.close()
    var data = Data()
    if capture {
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 32_768), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 512 * 1024 { p.terminate(); throw UpdateFailure("배포 파일의 목록이 너무 큽니다.") }
        }
    }
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

private func checksum(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    guard try file.seekToEnd() <= UInt64(limit) else { throw UpdateFailure("설치 ZIP이 너무 큽니다.") }
    try file.seek(toOffset: 0)
    var sha = SHA256()
    while let part = try file.read(upToCount: 1_048_576), !part.isEmpty { sha.update(data: part) }
    return sha.finalize().map { String(format: "%02x", $0) }.joined()
}

private func extract(_ zip: URL, folder: URL, release: RecorderRelease) throws -> URL {
    let root = String(release.archiveName.dropLast(4))
    let (status, listing) = try command("/usr/bin/zipinfo", ["-l-h-t", zip.path], capture: true)
    guard status == 0, let text = String(data: listing, encoding: .utf8), !text.isEmpty else { throw UpdateFailure("설치 ZIP을 읽을 수 없습니다.") }
    var size = 0
    for line in text.split(whereSeparator: \.isNewline) {
        let fields = line.split(maxSplits: 9, whereSeparator: \.isWhitespace)
        guard fields.count == 10, fields[0].first == "-" || fields[0].first == "d",
              let bytes = Int(fields[3]), (0...(limit - size)).contains(bytes),
              fields[9].hasPrefix(root + "/"), !fields[9].contains("\\"),
              !fields[9].split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw UpdateFailure("배포 ZIP에 허용되지 않은 파일이 있습니다.")
        }
        size += bytes
    }
    guard try command("/usr/bin/ditto", ["--qtn", "-x", "-k", zip.path, folder.path]).0 == 0 else { throw UpdateFailure("배포 ZIP을 풀지 못했습니다.") }
    return folder.appendingPathComponent(root + "/Meeting Recorder.app")
}

private func version(_ app: URL) throws -> RecorderRelease {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
          let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
          info["CFBundleIdentifier"] as? String == bundleID, info["CFBundleExecutable"] as? String == "MeetingRecorder",
          let raw = info["CFBundleShortVersionString"] as? String, let version = RecorderRelease(raw),
          let minimum = info["LSMinimumSystemVersion"] as? String else { throw UpdateFailure("미팅 레코더 배포 앱을 확인할 수 없습니다.") }
    let mac = ProcessInfo.processInfo.operatingSystemVersion
    let installed = "\(mac.majorVersion).\(mac.minorVersion).\(mac.patchVersion)"
    guard minimum.compare(installed, options: .numeric) != .orderedDescending else { throw UpdateFailure("이 버전은 macOS \(minimum) 이상이 필요합니다.") }
    return version
}

private func signature(_ url: URL) throws -> (SecStaticCode, SecRequirement) {
    var code: SecStaticCode?, requirement: SecRequirement?
    let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures))
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
          SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
        throw UpdateFailure("앱 서명 검증에 실패했습니다. 공식 배포본을 확인해 주세요.")
    }
    return (code, requirement)
}

private func verifyUpdate(from current: URL, to candidate: URL) throws {
    for path in ["", "Contents/MacOS/MeetingRecorderMCP"] {
        let (old, oldID) = try signature(path.isEmpty ? current : current.appendingPathComponent(path))
        let (new, newID) = try signature(path.isEmpty ? candidate : candidate.appendingPathComponent(path))
        guard SecStaticCodeCheckValidity(new, [], oldID) == errSecSuccess, SecStaticCodeCheckValidity(old, [], newID) == errSecSuccess else {
            throw UpdateFailure("기존 앱과 새 앱의 서명이 달라 설치를 중단했습니다.")
        }
    }
}

private func mainIsRunning(at app: URL) throws -> Bool {
    let path = app.appendingPathComponent("Contents/MacOS/MeetingRecorder").path
    let pattern = "^" + NSRegularExpression.escapedPattern(for: path) + "([[:space:]]|$)"
    let result = try command("/usr/bin/pgrep", ["-f", pattern]).0
    guard result == 0 || result == 1 else { throw UpdateFailure("실행 중인 레코더를 확인할 수 없습니다.") }
    return result == 0
}

private func runUpdate() throws {
    let args = CommandLine.arguments, parentPID = getppid()
    guard args.count == 5, parentPID > 1, args[1].hasPrefix("/"), args[1].hasSuffix(".app"),
          let release = RecorderRelease(args[2]) else { throw UpdateFailure("업데이트 요청이 올바르지 않습니다.") }
    let app = URL(fileURLWithPath: args[1]).standardizedFileURL
    let folder = app.deletingLastPathComponent(), zip = URL(fileURLWithPath: args[4])
    let oldVersion = try version(app)
    guard oldVersion < release else { throw UpdateFailure("현재보다 새로운 버전만 설치할 수 있습니다.") }
    guard !app.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: folder.path) else {
        throw UpdateFailure("앱을 쓰기 가능한 응용 프로그램 폴더로 옮긴 뒤 다시 시도하세요.")
    }

    let lock = folder.appendingPathComponent(".meeting-recorder-install.lock")
    guard mkdir(lock.path, 0o700) == 0 else { throw UpdateFailure("설치 폴더를 잠글 수 없습니다. 다른 설치가 진행 중인지 확인하세요.") }
    defer { _ = rmdir(lock.path) }
    guard try checksum(zip) == args[3] else { throw UpdateFailure("다운로드 파일의 SHA-256이 일치하지 않습니다. 다시 확인해 주세요.") }
    let work = folder.appendingPathComponent(".meeting-recorder-update-" + UUID().uuidString)
    try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: work) }
    let incoming = try extract(zip, folder: work, release: release)
    guard try version(incoming) == release else { throw UpdateFailure("다운로드한 앱의 버전이 요청과 다릅니다.") }
    try verifyUpdate(from: app, to: incoming)

    let backups = folder.appendingPathComponent(".meeting-recorder-backups")
    try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard try backups.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw UpdateFailure("백업 폴더가 심볼릭 링크입니다.") }
    let backup = backups.appendingPathComponent("previous-" + UUID().uuidString)
    try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var exchanged = false
    defer { if !exchanged { try? fm.removeItem(at: backup) } }
    let candidate = backup.appendingPathComponent(app.lastPathComponent)
    try fm.moveItem(at: incoming, to: candidate)

    // The parent can decline if a recording started during download or verification.
    try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
    guard readLine() == "INSTALL" else { return }
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while kill(parentPID, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline { usleep(100_000) }
    guard kill(parentPID, 0) == -1 && errno == ESRCH else { throw UpdateFailure("레코더가 종료되지 않아 설치를 중단했습니다.") }

    do {
        for _ in 0..<30 {
            if try !mainIsRunning(at: app) { break }
            usleep(100_000)
        }
        guard try !mainIsRunning(at: app), try version(app) == oldVersion else { throw UpdateFailure("다른 레코더가 실행되었거나 설치 버전이 바뀌었습니다.") }
        try verifyUpdate(from: app, to: candidate)
        // Both directories are on the same volume. A swap keeps the old MCP inode
        // in the backup and always leaves a complete app at the original path.
        guard renamex_np(app.path, candidate.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateFailure("이 위치에서 앱을 교체할 수 없습니다.") }
        exchanged = true
        guard try command("/usr/bin/open", ["-n", app.path]).0 == 0 else { throw UpdateFailure("새 앱을 다시 열지 못했습니다.") }
    } catch {
        if exchanged, renamex_np(app.path, candidate.path, UInt32(RENAME_SWAP)) == 0 { exchanged = false }
        let prefs = UserDefaults(suiteName: bundleID)
        prefs?.set(error.localizedDescription, forKey: "lastUpdateInstallError")
        prefs?.synchronize()
        if (try? mainIsRunning(at: app)) == false { _ = try? command("/usr/bin/open", [app.path]) }
        throw error
    }
}

do {
    // The parent is allowed to quit immediately after the handoff.
    signal(SIGPIPE, SIG_IGN)
    try runUpdate()
} catch {
    try? FileHandle.standardOutput.write(contentsOf: Data(("ERROR " + error.localizedDescription.replacingOccurrences(of: "\n", with: " ") + "\n").utf8))
    exit(1)
}
