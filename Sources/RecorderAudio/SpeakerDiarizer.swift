import CoreML
import FluidAudio
import Foundation
import RecorderCore

public enum SpeakerDiarizer {
    public static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecorder/Diarization", isDirectory: true)
    }

    public static func canAnalyze(_ stored: StoredMeeting) -> Bool {
        guard stored.meeting.segments.contains(where: { $0.source == .system }) else { return false }
        let system = stored.meeting.audioChunks.filter { $0.source == .system }
        if !system.isEmpty && system.allSatisfy({ chunk in
            guard let url = try? MeetingStore.chunkURL(chunk.fileName, in: stored.directory) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }) { return true }
        // Legacy mono exports cannot isolate the far-end from a speaking mic.
        return !stored.meeting.segments.contains { $0.source == .microphone } &&
            FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("audio.m4a").path)
    }

    /// Call from a detached worker so model loading and clustering never block UI.
    public static func analyze(_ stored: StoredMeeting, modelsDirectory: URL? = nil,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Meeting {
        try Task.checkCancellation()
        guard stored.meeting.segments.contains(where: { $0.source == .system }) else {
            return SpeakerAttribution.apply([], to: stored.meeting)
        }
        let chunks = stored.meeting.audioChunks.filter { $0.source == .system }
        let temporary = stored.directory.appendingPathComponent(".speaker-input.m4a")
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        let audio: URL
        if !chunks.isEmpty && chunks.allSatisfy({
            guard let url = try? MeetingStore.chunkURL($0.fileName, in: stored.directory) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }) {
            progress("상대방 오디오 준비 중…")
            let warnings = try await AudioExporter.export(chunks: chunks, directory: stored.directory, fileName: ".speaker-input.m4a")
            guard warnings.isEmpty else { throw RecorderError.message("상대방 오디오 일부를 읽지 못해 화자 분리를 보류했습니다.") }
            audio = temporary
        } else {
            guard canAnalyze(stored) else {
                throw RecorderError.message("이 기록에는 분리된 상대방 오디오가 없습니다. 새 녹음부터 참석자별 구분을 사용할 수 있습니다.")
            }
            audio = stored.directory.appendingPathComponent("audio.m4a")
        }
        let turns = try await turns(in: audio, modelsDirectory: modelsDirectory, progress: progress)
        try Task.checkCancellation()
        // Optional speaker labeling reuses the live words; it never runs ASR.
        return SpeakerAttribution.apply(turns, to: stored.meeting)
    }

    public static func turns(in audio: URL, modelsDirectory: URL? = nil,
                             progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [SpeakerTurn] {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        // No ASR/TTS models are loaded. Run only the offline diarizer, in small
        // embedding batches; file input is streamed from disk by FluidAudio.
        var config = OfflineDiarizerConfig()
        config.embeddingBatchSize = 8
        config.exclusiveSegments = true
        let manager = OfflineDiarizerManager(config: config)
        let modelConfig = MLModelConfiguration()
        modelConfig.computeUnits = .all
        progress("화자 모델 준비 중… 처음에는 모델을 다운로드합니다")
        try await manager.prepareModels(directory: modelsDirectory ?? defaultModelsDirectory, configuration: modelConfig)
        try Task.checkCancellation()
        progress("참석자 목소리 분석 중…")
        let result: DiarizationResult
        do {
            result = try await manager.process(audio) { done, total in
                if total > 0 {
                    progress(done >= total ? "목소리를 화자별로 묶는 중…" : "발화 구간 분석 중… \(done * 100 / total)%")
                }
            }
        } catch OfflineDiarizationError.noSpeechDetected { return [] }
        try Task.checkCancellation()
        return result.segments.map {
            SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}
