import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

public enum RecorderError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// Each converter is owned by one audio queue. Never pass it between capture lanes.
public final class PCMConverter {
    private var converter: AVAudioConverter?
    public let outputFormat: AVAudioFormat
    public init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }

    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if input.format == outputFormat { return input }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { throw RecorderError.message("오디오 형식을 변환할 수 없습니다.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw RecorderError.message("오디오 버퍼를 만들 수 없습니다.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw RecorderError.message("오디오 변환 중 오류가 발생했습니다.") }
        return output.frameLength > 0 ? output : nil
    }
}

public enum AudioBuffers {
    public static func copy(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw RecorderError.message("오디오 형식 정보가 없습니다.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw RecorderError.message("비어 있는 오디오 버퍼입니다.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw RecorderError.message("오디오 버퍼 복사 실패: \(status)") }
        return buffer
    }

    public static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(Double(sum) / Double(buffer.frameLength))
        return min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60))
    }
}

// Small AAC chunks bound temporary disk use and retain closed chunks after a crash.
// The final M4A is mixed only after capture finishes.
public final class AudioChunkWriter {
    public let source: AudioSource
    public private(set) var chunks: [AudioChunk] = []
    private let directory: URL
    private let format: AVAudioFormat
    private let onChange: (AudioChunk) -> Void
    private var file: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var activeIndex: Int?
    private let chunkDuration: Double

    public init(source: AudioSource, directory: URL, format: AVAudioFormat, chunkDuration: Double = 30, onChange: @escaping (AudioChunk) -> Void) {
        self.source = source
        self.directory = directory
        self.format = format
        self.chunkDuration = chunkDuration
        self.onChange = onChange
    }

    public func write(_ buffer: AVAudioPCMBuffer, at offset: Double) throws {
        if let index = activeIndex {
            let expected = chunks[index].offset + Double(frameCount) / format.sampleRate
            if Double(frameCount) / format.sampleRate >= chunkDuration || abs(offset - expected) > 0.1 { close() }
        }
        if file == nil {
            let name = "\(source.rawValue)-\(String(format: "%06d", chunks.count)).m4a"
            let url = try MeetingStore.chunkURL(name, in: directory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            frameCount = 0
            chunks.append(AudioChunk(fileName: name, source: source, offset: max(0, offset)))
            activeIndex = chunks.count - 1
            onChange(chunks[chunks.count - 1])
        }
        try file?.write(from: buffer)
        frameCount += AVAudioFramePosition(buffer.frameLength)
    }

    public func close() {
        guard let index = activeIndex else { return }
        file = nil // Finalizes the AAC container before marking the chunk durable.
        chunks[index].duration = Double(frameCount) / format.sampleRate
        chunks[index].finalized = true
        onChange(chunks[index])
        activeIndex = nil
        frameCount = 0
    }
}
