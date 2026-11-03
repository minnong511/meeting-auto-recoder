import Foundation

/// A critically damped expansion that retains velocity when its target changes.
/// Exact integration keeps the same timing on 60 Hz and 120 Hz displays.
public struct RecordingIslandMotion {
    public private(set) var progress = 0.0
    public private(set) var velocity = 0.0
    public private(set) var target = 0.0
    private let response = 22.0

    public init() {}

    public var isSettled: Bool { abs(progress - target) < 0.001 && abs(velocity) < 0.01 }

    public mutating func retarget(expanded: Bool) { target = expanded ? 1 : 0 }

    public mutating func snap(expanded: Bool) {
        target = expanded ? 1 : 0
        progress = target
        velocity = 0
    }

    public mutating func advance(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        let displacement = progress - target
        let coefficient = velocity + response * displacement
        let decay = exp(-response * seconds)
        progress = target + (displacement + coefficient * seconds) * decay
        velocity = (velocity - response * coefficient * seconds) * decay
        if progress < 0 || progress > 1 {
            progress = min(1, max(0, progress))
            velocity = 0
        }
        if isSettled { progress = target; velocity = 0 }
    }
}
