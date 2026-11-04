import AVFoundation
import Combine
import Foundation
import RecorderCore

@MainActor
final class RecordingPlayer: ObservableObject {
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hasStarted = false
    @Published private(set) var meetingID: UUID?
    @Published private(set) var errorMessage: String?
    static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    @Published private(set) var rate: Double
    @Published private(set) var volume: Double
    @Published private(set) var isMuted: Bool
    var effectiveVolume: Double { isMuted ? 0 : volume }
    private let preferences: UserDefaults
    private var player: AVPlayer?
    private var observer: Any?
    private var durationTask: Task<Void, Never>?
    private var seekID = UUID()
    private var isSeeking = false
    private var isScrubbing = false
    private var resumeAfterScrubbing = false
    private var playAfterSeek = false
    private var wantsPlayback: Bool { isPlaying || (isSeeking && playAfterSeek) }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let speed = preferences.double(forKey: "playbackRate")
        rate = Self.rates.contains(speed) ? speed : 1
        let gain = preferences.double(forKey: "playbackVolume")
        volume = gain.isFinite && gain > 0 ? min(gain, 1) : 1
        isMuted = preferences.bool(forKey: "playbackMuted")
    }

    func setRate(_ value: Double) {
        guard Self.rates.contains(value), rate != value else { return }
        rate = value
        preferences.set(value, forKey: "playbackRate")
        player?.defaultRate = Float(value)
        if isPlaying { player?.rate = Float(value) }
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        let gain = min(max(0, value), 1)
        if gain > 0, volume != gain {
            volume = gain
            preferences.set(gain, forKey: "playbackVolume")
            player?.volume = Float(gain)
        }
        setMuted(gain == 0)
    }

    func toggleMute() { setMuted(!isMuted) }

    private func setMuted(_ value: Bool) {
        guard value != isMuted else { return }
        isMuted = value
        preferences.set(value, forKey: "playbackMuted")
        player?.isMuted = value
    }


    @discardableResult
    func prepare(_ stored: StoredMeeting) -> Bool {
        if meetingID == stored.id, player != nil { return true }
        reset()
        guard let url = stored.audioURL, FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "녹음 파일을 찾을 수 없습니다. 파일 위치를 확인해 주세요."
            return false
        }
        meetingID = stored.id
        duration = max(0, stored.meeting.endedAt?.timeIntervalSince(stored.meeting.startedAt) ?? 0)
        let loaded = AVPlayer(url: url)
        loaded.defaultRate = Float(rate)
        loaded.volume = Float(volume)
        loaded.isMuted = isMuted
        loaded.currentItem?.audioTimePitchAlgorithm = .timeDomain
        player = loaded
        observer = loaded.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.meetingID == stored.id, !self.isScrubbing, !self.isSeeking else { return }
                let value = time.seconds
                guard value.isFinite else { return }
                self.position = max(0, value)
            }
        }
        durationTask = Task { [weak self] in
            guard let seconds = try? await loaded.currentItem?.asset.load(.duration).seconds,
                  seconds.isFinite, seconds > 0, !Task.isCancelled,
                  let self, self.meetingID == stored.id else { return }
            self.duration = seconds
            self.position = min(self.position, seconds)
        }
        return true
    }

    func reset() {
        durationTask?.cancel(); durationTask = nil
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil; player = nil; meetingID = nil
        seekID = UUID(); isSeeking = false; isScrubbing = false; playAfterSeek = false
        resumeAfterScrubbing = false; isPlaying = false; hasStarted = false
        position = 0; duration = 0; errorMessage = nil
    }

    func pause() {
        if isScrubbing, let time = player?.currentTime().seconds, time.isFinite { position = max(0, time) }
        isScrubbing = false; resumeAfterScrubbing = false
        seekID = UUID(); isSeeking = false; playAfterSeek = false
        player?.currentItem?.cancelPendingSeeks()
        player?.pause(); isPlaying = false
    }

    func toggle(_ stored: StoredMeeting) {
        guard prepare(stored) else { return }
        if wantsPlayback { pause() }
        else if isSeeking { seek(to: position, in: stored, autoplay: true) }
        else if duration > 0, position >= duration - 0.1 { seek(to: 0, in: stored, autoplay: true) }
        else { hasStarted = true; player?.play(); isPlaying = true }
    }

    func seek(to seconds: Double, in stored: StoredMeeting, autoplay: Bool) {
        guard seconds.isFinite, prepare(stored), let player else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        let request = UUID(); seekID = request
        hasStarted = true; isSeeking = true; playAfterSeek = autoplay; position = target
        player.pause(); isPlaying = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.meetingID == stored.id, self.seekID == request else { return }
                self.isSeeking = false; self.playAfterSeek = false
                if finished, autoplay { self.player?.play(); self.isPlaying = true }
            }
        }
    }

    func skip(_ seconds: Double, in stored: StoredMeeting) {
        seek(to: position + seconds, in: stored, autoplay: wantsPlayback)
    }

    func scrub(_ editing: Bool, in stored: StoredMeeting) {
        if editing {
            guard !isScrubbing, prepare(stored) else { return }
            let resume = wantsPlayback
            pause()
            resumeAfterScrubbing = resume
            isScrubbing = true
        } else {
            guard isScrubbing, meetingID == stored.id else { return }
            let resume = resumeAfterScrubbing
            resumeAfterScrubbing = false
            isScrubbing = false
            seek(to: position, in: stored, autoplay: resume)
        }
    }

    func scrubPosition(_ seconds: Double, in stored: StoredMeeting) {
        guard seconds.isFinite else { return }
        if isScrubbing { position = min(max(0, seconds), duration) }
        else { seek(to: seconds, in: stored, autoplay: wantsPlayback) }
    }

    func finished(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
        isPlaying = false
        if duration > 0 { position = duration }
    }

    deinit {
        durationTask?.cancel()
        if let observer { player?.removeTimeObserver(observer) }
    }
}
