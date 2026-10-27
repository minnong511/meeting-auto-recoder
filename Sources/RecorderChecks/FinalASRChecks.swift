import AVFoundation
import Foundation
import RecorderAudio
import RecorderCore

extension RecorderChecks {
    func finalTranscriptBoundaries() throws {
        let turns = [SpeakerTurn(speakerID: "one", start: 0, end: 4), SpeakerTurn(speakerID: "two", start: 4, end: 8),
                     SpeakerTurn(speakerID: "two", start: 9, end: 48)]
        var prior = TranscriptSegment(source: .system, start: 0, end: 48, text: "네")
        prior.words = [TranscriptWord(text: "네", start: 8.2, end: 8.5)]
        let jobs = FinalTranscriptPlan.jobs(turns: turns, microphone: [(1, 2), (5, 6)], systemDuration: 48, microphoneDuration: 8, prior: [prior])
        try expect(jobs.allSatisfy { $0.end > $0.start && $0.end - $0.start <= 24 }, "최종 전사 창 제한 실패")
        try expect(!jobs.contains { $0.source == .system && $0.start < 4 && $0.end > 4 }, "화자 경계를 넘은 전사")
        try expect(jobs.filter { $0.source == .microphone }.map(\.start) == [1, 5], "마이크 꺼짐 간격이 합쳐짐")
        let retained = FinalTranscriptPlan.uncovered([prior], jobs: jobs)
        try expect(retained.count == 1 && retained[0].text == "네", "화자 감지에서 빠진 짧은 대답 삭제")
    }

    func finalTranscriptWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("final-asr-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ProcessInfo.processInfo.environment["MEETING_RECORDER_ASR_CONFIG"]
        defer { if let old { setenv("MEETING_RECORDER_ASR_CONFIG", old, 1) } else { unsetenv("MEETING_RECORDER_ASR_CONFIG") } }
        let python = "/usr/bin/python3"
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        let worker = root.appendingPathComponent("worker.py")
        let script = """
        import json,sys
        from pathlib import Path
        request=json.loads(Path(sys.argv[2]).read_text())
        Path(sys.argv[3]).write_text(json.dumps([dict(id=j['id'],text='검증된 발언입니다.') for j in request['jobs']]))
        """
        try script.write(to: worker, atomically: true, encoding: .utf8)
        let config = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["engine":"qwen17", "python":python,"model":model.path,"worker":worker.path]).write(to: config)
        setenv("MEETING_RECORDER_ASR_CONFIG", config.path, 1)
        let input = root.appendingPathComponent("input.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000)!
            buffer.frameLength = 64_000
            for i in 0..<64_000 { buffer.floatChannelData![0][i] = i < 16_000 || i >= 48_000 ? 0.02 : 0 }
            try file.write(from: buffer)
        }
        let turns = [SpeakerTurn(speakerID: "a", start: 0, end: 2), SpeakerTurn(speakerID: "b", start: 2, end: 4)]
        var meeting = Meeting(title: "원본 보존")
        meeting.segments = [TranscriptSegment(source: .system, start: 0, end: 4, text: "기존 대화록")]
        let updated = try await FinalASR.refine(systemAudio: input, microphoneAudio: input, turns: turns, meeting: meeting)
        try expect(updated.diarization?.speakerCount == 2, "최종 전사의 화자 구분 손실")
        try expect(updated.segments.filter { $0.source == .microphone }.count == 2, "마이크 무음 간격을 발화로 저장함")
        try expect(updated.transcriptionEngine?.hasPrefix("Qwen3-ASR") == true, "최종 엔진 식별자 없음")
        try "import sys\nsys.exit(1)\n".write(to: worker, atomically: true, encoding: .utf8)
        do {
            _ = try await FinalASR.refine(systemAudio: input, turns: turns, meeting: meeting)
            throw CheckError.failed("실패한 워커를 성공으로 처리함")
        } catch let error as CheckError { throw error } catch {}
        try expect(meeting.segments[0].text == "기존 대화록" && meeting.transcriptionEngine == nil, "실패한 최종 전사가 기존 대화록을 변경함")
        try "import time\ntime.sleep(5)\n".write(to: worker, atomically: true, encoding: .utf8)
        let task = Task { try await FinalASR.refine(systemAudio: input, turns: turns, meeting: meeting) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; throw CheckError.failed("취소 후 결과를 저장함") }
        catch is CancellationError {} catch { throw error }
    }
}
