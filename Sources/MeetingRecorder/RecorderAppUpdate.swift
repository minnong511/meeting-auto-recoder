import AppKit
import Darwin
import Foundation
import RecorderCore

private struct UpdateHandoff {
    let command: FileHandle

    static func prepare(_ release: RecorderRelease, app: URL) async throws -> Self {
        let digest = try await release.fetchChecksum()
        let request = URLRequest(url: release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw MCPError.message("GitHub에서 설치 ZIP을 받지 못했습니다. 다시 시도해 주세요.")
        }
        return try await Task.detached(priority: .utility) {
            let helper = Process(), input = Pipe(), output = Pipe()
            helper.executableURL = app.appendingPathComponent("Contents/MacOS/MeetingRecorderUpdater")
            helper.arguments = [app.path, release.description, digest, file.path]
            helper.standardInput = input; helper.standardOutput = output; helper.standardError = FileHandle.nullDevice
            try helper.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            var line = Data()
            let reader = output.fileHandleForReading
            defer { try? reader.close() }
            while line.count < 4096, let byte = try reader.read(upToCount: 1), !byte.isEmpty, byte.first != 10 {
                line.append(byte)
            }
            let message = String(decoding: line, as: UTF8.self)
            guard message == "READY" else {
                try? writer.close()
                throw MCPError.message(message.hasPrefix("ERROR ") ? String(message.dropFirst(6)) : "설치를 준비하지 못했습니다. 다시 시도해 주세요.")
            }
            return Self(command: writer)
        }.value
    }
}

extension RecorderModel {
    var canInstallUpdate: Bool { !isBusy && !isSeparatingSpeakers && summarizingID == nil && !isInstallingUpdate && !isQuitting }

    func installUpdate(_ version: RecorderRelease) {
        guard canInstallUpdate, updates.available == version else { return }
        updateInstallError = nil
        isInstallingUpdate = true
        Task {
            defer { isInstallingUpdate = false }
            do {
                let prepared = try await UpdateHandoff.prepare(version, app: Bundle.main.bundleURL)
                defer { try? prepared.command.close() }
                guard !isQuitting, !isBusy, !isSeparatingSpeakers, summarizingID == nil else {
                    throw MCPError.message("진행 중인 작업이 끝난 뒤 다시 설치해 주세요.")
                }
                try prepared.command.write(contentsOf: Data("INSTALL\n".utf8))
                isQuitting = true
                NSApp.terminate(nil)
            } catch {
                updateInstallError = error.localizedDescription
                openSettings(.general)
            }
        }
    }
}
