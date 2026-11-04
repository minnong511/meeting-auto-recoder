import AVFoundation
import Foundation
import RecorderAudio

extension RecorderChecks {
    func playbackWaveform() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        func write(_ url: URL, frames: AVAudioFrameCount, peaks: [Float]) throws {
            let out = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            pcm.frameLength = frames
            let data = pcm.floatChannelData!
            for frame in 0..<Int(frames) {
                let bin = frame * peaks.count / Int(frames)
                // Right-only speech and anti-phase channels must survive the mix-down for display.
                data[0][frame] = bin.isMultiple(of: 2) ? 0 : -peaks[bin]
                data[1][frame] = peaks[bin]
            }
            try out.write(from: pcm)
        }
        let expected: [Float] = [0, 0.1, 0.6, 0.05, 0, 0.97, 0.02, 0.3]
        try write(file, frames: 80_000, peaks: expected)
        let signal = try await PlaybackWaveform.load(at: file, bins: 8)
        try expect(signal.isComplete && signal.peaks.count == 8 && zip(signal.peaks, expected).allSatisfy { abs($0 - $1) < 0.0001 },
                   "무음·오른쪽 채널·경계 음량이 실제 녹음과 다름")
        let single = try await PlaybackWaveform.load(at: file, bins: 1)
        try expect(single.peaks == [0.97], "짧은 피크가 축소 과정에서 누락됨")
        let replacement = root.appendingPathComponent("new.caf")
        try write(replacement, frames: 3, peaks: [0, 0.2, 0])
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        let revised = try await PlaybackWaveform.load(at: file, bins: 8)
        try expect(revised.isComplete && revised.peaks == [0, 0.2, 0], "교체한 파일 또는 아주 짧은 파일의 파형이 틀림")
    }
}
