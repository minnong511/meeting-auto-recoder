import Foundation

struct MCPDiagnosticResult: Sendable {
    let succeeded: Bool
    let message: String
}

enum MCPDiagnostics {
    static func check(executable: URL, root: URL?) async -> MCPDiagnosticResult {
        await Task.detached(priority: .utility) {
            do {
                var isDirectory: ObjCBool = false
                guard let root, FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                      isDirectory.boolValue, FileManager.default.isReadableFile(atPath: root.path) else {
                    return MCPDiagnosticResult(succeeded: false, message: "저장 폴더를 선택하거나 폴더 접근 권한을 확인해 주세요.")
                }
                let process = Process()
                let input = Pipe()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = ["--connection-check"]
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                    if process.isRunning { process.terminate() }
                }
                let requests: [[String: Any]] = [
                    ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Meeting Recorder 진단", "version": "1"]]],
                    ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                    ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_meetings", "arguments": [:]]]
                ]
                for request in requests {
                    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
                }
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NSError(domain: "MCPDiagnostic", code: 1) }
                let responses = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
                func result(_ id: Int) -> [String: Any]? {
                    responses.first { ($0["id"] as? Int) == id }?["result"] as? [String: Any]
                }
                let info = result(1)?["serverInfo"] as? [String: Any]
                let tools = result(2)?["tools"] as? [[String: Any]] ?? []
                let names = Set(tools.compactMap { $0["name"] as? String })
                guard info?["name"] as? String == "meeting-recorder",
                      names.isSuperset(of: ["list_meetings", "get_transcript", "get_meeting_paths", "save_summary"]),
                      let meetings = result(3), meetings["isError"] as? Bool == false else {
                    return MCPDiagnosticResult(succeeded: false, message: "MCP 서버 또는 저장 폴더를 확인하지 못했습니다.")
                }
                return MCPDiagnosticResult(succeeded: true, message: "MCP 서버와 저장 폴더가 정상 작동합니다.")
            } catch {
                return MCPDiagnosticResult(succeeded: false, message: "MCP 서버를 실행하지 못했습니다. 앱 설치와 저장 폴더를 확인해 주세요.")
            }
        }.value
    }
}
