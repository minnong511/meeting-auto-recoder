import Accelerate
import AVFoundation
import Foundation

/// Peak amplitudes of equal intervals of the exported audio, across all channels.
package struct PlaybackWaveform: Sendable {
    package let peaks: [Float]
    package let availableBins: Int
    package var isComplete: Bool { availableBins == peaks.count }

    private final class Entry: NSObject {
        let value: PlaybackWaveform
        init(_ value: PlaybackWaveform) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 12
        return cache
    }()

    package static func load(at url: URL, bins: Int = 1_536,
                             progress: (@Sendable (PlaybackWaveform) -> Void)? = nil) async throws -> PlaybackWaveform {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let revision = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate.bitPattern
            let size = attributes[.size] as? NSNumber
            let inode = attributes[.systemFileNumber] as? NSNumber
            let key = "\(url.standardizedFileURL.path)|\(revision ?? 0)|\(size ?? 0)|\(inode ?? 0)|\(bins)" as NSString
            if let cached = cache.object(forKey: key) { return cached.value }
            let value = try decode(url, bins: bins, progress: progress)
            try Task.checkCancellation()
            cache.setObject(Entry(value), forKey: key)
            return value
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func decode(_ url: URL, bins requested: Int,
                               progress: (@Sendable (PlaybackWaveform) -> Void)?) throws -> PlaybackWaveform {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = file.length
        guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
              let channels = buffer.floatChannelData else { throw RecorderError.message("파형을 읽을 수 없습니다.") }
        let target = Int64(min(4_096, max(1, requested)))
        let framesPerBin = (length - 1) / target + 1
        var peaks = [Float](repeating: 0, count: Int((length - 1) / framesPerBin + 1))
        var offset: Int64 = 0
        var lastUpdate = ContinuousClock.now
        while offset < length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), length - offset))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            let limit = offset + Int64(buffer.frameLength)
            var frame = offset
            while frame < limit {
                let index = Int(frame / framesPerBin)
                let end = min(limit, (Int64(index) + 1) * framesPerBin)
                let start = Int(frame - offset)
                for channel in 0..<Int(buffer.format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel].advanced(by: start), 1, &peak, vDSP_Length(end - frame))
                    if peak.isFinite { peaks[index] = max(peaks[index], peak) }
                }
                frame = end
            }
            offset = limit
            if let progress, lastUpdate.duration(to: .now) >= .milliseconds(180), offset < length {
                progress(PlaybackWaveform(peaks: peaks, availableBins: Int(offset / framesPerBin)))
                lastUpdate = .now
            }
        }
        guard offset > 0 else { throw RecorderError.message("파형을 읽을 수 없습니다.") }
        return PlaybackWaveform(peaks: peaks, availableBins: peaks.count)
    }
}
