import AVFoundation
import Foundation
import RecorderAudio
import RecorderCore

/// Integration probe with real models, kept separate from model-free regression checks.
@MainActor func checkDuplex(model: SpeechModel, path: String) async throws {
    try await SpeechLane.prepareAssets(model: model)
    var mic: [TranscriptSegment] = [], system: [TranscriptSegment] = []
    let a = try await SpeechLane.create(source: .system, onResult: { if $1 && !$0.text.isEmpty { system.append($0) } }, onError: { _ in })
    let b = try await SpeechLane.create(source: .microphone, onResult: { if $1 && !$0.text.isEmpty { mic.append($0) } }, onError: { _ in })
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard file.processingFormat.sampleRate == 16_000, file.length > 0, file.length <= 30*16_000 else {
            throw RecorderError.message("Use one of the short 16 kHz reference files.")
        }
        let converter = PCMConverter(outputFormat: format)
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        guard let pcm = try converter.convert(input), let values = pcm.floatChannelData?[0] else { throw RecorderError.message("Invalid audio.") }
        let voice = Array(UnsafeBufferPointer(start: values, count: Int(pcm.frameLength))) + Array(repeating: Float(0), count: 32_768)
        var offset = 0
        // System speaks twice; the first microphone turn is only nonspeech. In the second turn both speak.
        for turn in 0..<2 {
            for i in stride(from: 0, to: voice.count, by: 4096) {
                let count = min(voice.count-i, 4096)
                func buffer(_ muted: Bool) -> AVAudioPCMBuffer {
                    let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    result.frameLength = AVAudioFrameCount(count)
                    let out = result.floatChannelData![0]
                    for j in 0..<count { out[j] = muted ? 0.004 * sin(Float(i+j) * 2 * .pi * 60 / 16_000) : voice[i+j] }
                    return result
                }
                let t = Double(offset+i)/16_000
                try a.consume(buffer(false), at: t)
                try b.consume(buffer(turn == 0), at: t)
                async let systemBarrier: Void = a.synchronize()
                async let micBarrier: Void = b.synchronize()
                _ = try await (systemBarrier, micBarrier)
            }
            offset += voice.count
        }
        async let finishA: Void = a.finish()
        async let finishB: Void = b.finish()
        _ = try await (finishA, finishB)
        let boundary = Double(voice.count)/16_000
        guard system.contains(where: { $0.start < boundary - 1 }),
              system.contains(where: { $0.end > boundary + 1 }),
              !mic.isEmpty, mic.allSatisfy({ $0.start >= boundary - 0.6 && $0.end > boundary }) else {
            throw RecorderError.message("두 입력의 발화 또는 무발화 구간이 섞였습니다.")
        }
        print("PASS simultaneous microphone/system; first microphone turn empty; both subsequent speech turns finalized.")
    } catch {
        await a.cancel(); await b.cancel(); await SpeechLane.releaseAssets(); throw error
    }
    await SpeechLane.releaseAssets()
}
