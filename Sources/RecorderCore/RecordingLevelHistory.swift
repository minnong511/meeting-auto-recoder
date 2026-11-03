import Foundation

/// A short history of measured input levels, not a decorative waveform.
/// Frame counters expire each input independently when capture stops delivering audio.
public struct RecordingLevelHistory {
    public static let sampleCount = 36
    public private(set) var levels = Array(repeating: 0.0, count: sampleCount)
    private var system = Input()
    private var microphone = Input()

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func sample(systemLevel: Double, systemFrames: Int64,
                                microphoneLevel: Double, microphoneFrames: Int64,
                                now: TimeInterval) {
        let systemValue = system.sample(level: systemLevel, frames: systemFrames, now: now)
        let microphoneValue = microphone.sample(level: microphoneLevel, frames: microphoneFrames, now: now)
        levels.removeFirst()
        levels.append(max(systemValue, microphoneValue))
    }

    private struct Input {
        var frames: Int64 = 0
        var updatedAt: TimeInterval?
        var value = 0.0

        mutating func sample(level: Double, frames: Int64, now: TimeInterval) -> Double {
            guard now.isFinite else { return 0 }
            let measured = level.isFinite ? min(1, max(0, level)) : 0
            if frames > 0 && frames != self.frames {
                updatedAt = now
                value = measured
            } else if measured == 0 {
                // A microphone gate can clear the level without adding frames.
                value = 0
            }
            self.frames = frames
            guard frames > 0, let updatedAt, now >= updatedAt, now - updatedAt < 0.3 else { return 0 }
            return value
        }
    }
}
