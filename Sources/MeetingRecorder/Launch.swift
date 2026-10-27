import AppKit
import AVFoundation
import Foundation
import RecorderAudio
import RecorderCore
import SwiftUI

@main
enum Launch {
    @MainActor
    static func main() async {
        if let path = argument("--final-asr-config") { setenv("MEETING_RECORDER_ASR_CONFIG", path, 1) }
        if CommandLine.arguments.contains("--notification-status") || CommandLine.arguments.contains("--capture-content") || argument("--capture-app-test") != nil {
            do {
                let data: Data
                if let bundleID = argument("--capture-app-test"), let output = argument("--output") {
                    data = try await RecorderDiagnostics.captureApp(bundleID, root: URL(fileURLWithPath: output))
                } else if CommandLine.arguments.contains("--capture-content") { data = try await RecorderDiagnostics.captureContent() }
                else { data = try await RecorderDiagnostics.notificationStatus() }
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--list-meeting-apps") {
            let apps = await MeetingAppMonitor.snapshot()
            print(String(decoding: (try? JSONEncoder().encode(apps)) ?? Data(), as: UTF8.self))
            return
        }
        let modelsDirectory = argument("--models").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if CommandLine.arguments.contains("--prepare-speech") {
            do {
                try await SpeechLane.prepareAssets { message in fputs("\(message)\n", stderr) }
                let report = await SpeechSupport.inspect()
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                await SpeechLane.releaseAssets()
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let path = argument("--diarize") {
            do {
                let task = Task.detached(priority: .utility) {
                    try await SpeakerDiarizer.turns(in: URL(fileURLWithPath: path), modelsDirectory: modelsDirectory)
                }
                let turns = try await task.value
                print(String(decoding: try JSONEncoder().encode(turns), as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let report = await SpeechSupport.inspect()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { print(String(decoding: try encoder.encode(report), as: UTF8.self)) }
            catch { fputs("\(error)\n", stderr) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), CommandLine.arguments.count > index + 1 {
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                try await SpeechLane.prepareAssets { message in fputs("\(message)\n", stderr) }
                let streamEvents = CommandLine.arguments.contains("--stream-events")
                let realTime = CommandLine.arguments.contains("--realtime")
                let started = ProcessInfo.processInfo.systemUptime
                var inputFinished = false
                var segments: [TranscriptSegment] = []
                var speechErrors: [String] = []
                let lane = try await SpeechLane.create(source: .system, emitPartials: realTime || streamEvents, onResult: { segment, final in
                    if streamEvents {
                        let event = StreamEvent(event: final ? "final" : "partial", elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                                inputFinished: inputFinished, audioStart: segment.start, audioEnd: segment.end, text: segment.text)
                        if let data = try? JSONEncoder().encode(event) { print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
                    }
                    if final { segments.append(segment) }
                }, onError: { error in Task { @MainActor in speechErrors.append(error) } })
                do {
                    let file = try AVAudioFile(forReading: url)
                    while file.framePosition < file.length {
                        let start = Double(file.framePosition) / file.processingFormat.sampleRate
                        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                        try file.read(into: buffer)
                        if buffer.frameLength > 0 { try lane.consume(buffer, at: start) }
                        if !realTime { try await lane.synchronize() }
                        if realTime {
                            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                        }
                    }
                    inputFinished = true
                    try await lane.finish()
                } catch { await lane.cancel(); await SpeechLane.releaseAssets(); throw error }
                await SpeechLane.releaseAssets()
                guard speechErrors.isEmpty else { throw RecorderError.message(speechErrors.joined(separator: "; ")) }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if CommandLine.arguments.contains("--with-speakers") {
                    var meeting = Meeting(title: url.deletingPathExtension().lastPathComponent)
                    meeting.transcriptionEngine = "WhisperKit · large-v3-v20240930_626MB · ko"
                    meeting.segments = segments
                    meeting.status = .completed
                    let turns = try await Task.detached(priority: .utility) {
                        try await SpeakerDiarizer.turns(in: url, modelsDirectory: modelsDirectory)
                    }.value
                    meeting = try await FinalASR.refine(systemAudio: url, turns: turns, meeting: meeting,
                        progress: { message in fputs("\(message)\n", stderr) })
                    print(String(decoding: try encoder.encode(meeting), as: UTF8.self))
                } else if !streamEvents { print(String(decoding: try encoder.encode(segments), as: UTF8.self)) }
                if segments.isEmpty { exit(2) }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        RecorderApp.main()
    }

    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

private struct StreamEvent: Encodable {
    let event: String
    let elapsedSeconds: Double
    let inputFinished: Bool
    let audioStart: Double
    let audioEnd: Double
    let text: String
}

struct RecorderApp: App {
    @StateObject private var model = RecorderModel()
    @NSApplicationDelegateAdaptor(RecorderAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: model).onAppear {
                delegate.model = model
                model.startMeetingMonitoring()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }.windowStyle(.automatic).defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra("Meeting Recorder", systemImage: model.phase == .recording ? "record.circle.fill" : "waveform") {
            Text(model.statusText)
            if model.phase == .recording {
                Button("녹음 종료") { Task { await model.stop() } }
            } else {
                ForEach(model.detectedMeetingApps) { app in
                    Button("\(app.name) 녹음") { model.begin(in: app) }.disabled(model.isBusy)
                }
                Button("선택한 앱 녹음", action: model.begin).disabled(!model.canBegin)
            }
            Button("창 보기") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@MainActor
final class RecorderAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        Task {
            await model.finishBeforeQuitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
