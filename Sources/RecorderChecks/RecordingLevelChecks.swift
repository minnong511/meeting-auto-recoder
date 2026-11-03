import AVFoundation
import Foundation
import RecorderAudio
import RecorderCore

extension RecorderChecks {
    func recordingLevelHistory() throws {
        // Exercise the same PCM -> level -> island history path used by capture.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        let samples = buffer.floatChannelData![0]
        for index in 0..<4_800 { samples[index] = 0.25 * sin(Float(index) * 2 * .pi * 440 / 48_000) }
        let measured = AudioBuffers.level(buffer)
        var meter = RecordingLevelHistory()
        meter.sample(systemLevel: measured, systemFrames: 4_800,
                     microphoneLevel: 0, microphoneFrames: 0, now: 1)
        try expect(measured > 0.1 && meter.levels.last == measured, "실제 오디오가 음량 바에 반영되지 않음")
        try expect(meter.levels.dropLast().allSatisfy { $0 == 0 }, "입력이 없는 과거 구간에 파형을 만듦")

        for index in 0..<4_800 { samples[index] = 0 }
        meter.sample(systemLevel: AudioBuffers.level(buffer), systemFrames: 9_600,
                     microphoneLevel: 0, microphoneFrames: 0, now: 1.1)
        try expect(meter.levels.last == 0, "무음에서 음량을 표시함")

        meter.sample(systemLevel: 0.9, systemFrames: 14_400,
                     microphoneLevel: 0.2, microphoneFrames: 4_800, now: 2)
        meter.sample(systemLevel: 0.9, systemFrames: 14_400,
                     microphoneLevel: 0.2, microphoneFrames: 9_600, now: 2.4)
        try expect(meter.levels.last == 0.2, "중단된 시스템 입력이 계속되는 마이크 입력을 가림")
        meter.sample(systemLevel: 0.9, systemFrames: 14_400,
                     microphoneLevel: 0.2, microphoneFrames: 9_600, now: 3)
        try expect(meter.levels.last == 0, "입력이 끊겼는데 음량이 유지됨")
        meter.sample(systemLevel: 0, systemFrames: 14_400,
                     microphoneLevel: 0.7, microphoneFrames: 14_400, now: 4)
        meter.sample(systemLevel: 0, systemFrames: 14_400,
                     microphoneLevel: 0, microphoneFrames: 14_400, now: 4.1)
        try expect(meter.levels.last == 0, "마이크를 껐는데 음량이 남음")

        for index in 1...100 {
            meter.sample(systemLevel: .nan, systemFrames: Int64(20_000 + index),
                         microphoneLevel: .infinity, microphoneFrames: Int64(20_000 + index), now: Double(index + 5))
        }
        try expect(meter.levels.count == RecordingLevelHistory.sampleCount && meter.levels.allSatisfy { $0 == 0 },
                   "잘못된 음량 또는 무제한 기록이 전달됨")
        meter.sample(systemLevel: 2, systemFrames: 25_000,
                     microphoneLevel: -1, microphoneFrames: 25_000, now: 110)
        try expect(meter.levels.last == 1, "표시 음량 범위를 벗어남")
        meter.reset()
        try expect(meter.levels.allSatisfy { $0 == 0 }, "새 녹음에 이전 파형이 남음")
        meter.sample(systemLevel: measured, systemFrames: 4_800,
                     microphoneLevel: 0, microphoneFrames: 0, now: 120)
        try expect(meter.levels.last == measured, "새 녹음의 입력을 표시하지 못함")
    }
}
