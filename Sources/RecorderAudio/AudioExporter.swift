import AVFoundation
import Foundation
import RecorderCore

public enum AudioExporter {
    public static func export(chunks: [AudioChunk], directory: URL, fileName: String = "audio.m4a") async throws -> [String] {
        guard !fileName.isEmpty, fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains("/"), !fileName.contains("\\") else { throw StoreError.invalidFileName }
        let composition = AVMutableComposition()
        var tracks: [AudioSource: AVMutableCompositionTrack] = [:]
        var warnings: [String] = []
        var inserted = 0
        for chunk in chunks.sorted(by: { $0.offset < $1.offset }) {
            do {
                let url = try MeetingStore.chunkURL(chunk.fileName, in: directory)
                let asset = AVURLAsset(url: url)
                guard let input = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw RecorderError.message("오디오 트랙이 없습니다.")
                }
                let duration = try await asset.load(.duration)
                guard duration.seconds.isFinite, duration.seconds > 0 else { throw RecorderError.message("오디오 조각이 비어 있습니다.") }
                if tracks[chunk.source] == nil {
                    tracks[chunk.source] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                guard let output = tracks[chunk.source] else { throw RecorderError.message("오디오 트랙을 만들 수 없습니다.") }
                // AAC priming can extend a file slightly beyond its captured PCM duration.
                let actual = chunk.duration > 0 ? min(duration.seconds, chunk.duration) : duration.seconds
                try output.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: actual, preferredTimescale: 48_000)), of: input, at: CMTime(seconds: max(0, chunk.offset), preferredTimescale: 48_000))
                inserted += 1
            } catch {
                warnings.append("오디오 조각 \(chunk.fileName)을 복구하지 못했습니다: \(error.localizedDescription)")
            }
        }
        guard inserted > 0 else { throw RecorderError.message("저장할 오디오가 없습니다. 녹음 권한과 입력 장치를 확인해 주세요.") }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.message("M4A 내보내기를 시작할 수 없습니다.")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.values.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(tracks.count > 1 ? 0.5 : 1, at: .zero)
            return params
        }
        exporter.audioMix = mix
        let temporary = directory.appendingPathComponent("\(fileName)-exporting.m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try? FileManager.default.removeItem(at: temporary)
        try await exporter.export(to: temporary, as: .m4a)
        let final = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: final)
        }
        // The owner commits metadata before MeetingStore removes successful recovery chunks.
        return warnings
    }
}
