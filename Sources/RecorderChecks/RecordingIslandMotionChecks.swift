import Foundation
import RecorderCore

extension RecorderChecks {
    func recordingIslandMotion() throws {
        var sixty = RecordingIslandMotion()
        var oneTwenty = RecordingIslandMotion()
        sixty.retarget(expanded: true)
        oneTwenty.retarget(expanded: true)
        for _ in 0..<12 { sixty.advance(by: 1.0 / 60) }
        for _ in 0..<24 { oneTwenty.advance(by: 1.0 / 120) }
        try expect(abs(sixty.progress - oneTwenty.progress) < 0.000001,
                   "화면 주사율에 따라 펼치기 속도가 달라짐")
        try expect(abs(sixty.velocity - oneTwenty.velocity) < 0.000001,
                   "화면 주사율에 따라 이동 속도가 달라짐")

        var motion = RecordingIslandMotion()
        motion.retarget(expanded: true)
        motion.advance(by: 0.08)
        let position = motion.progress, velocity = motion.velocity
        motion.retarget(expanded: false)
        try expect(motion.progress == position && motion.velocity == velocity,
                   "펼치는 도중 접으면 위치나 속도가 갑자기 바뀜")
        motion.advance(by: 1.0 / 120)
        try expect(motion.progress > position && motion.velocity < velocity,
                   "방향 전환 때 기존 속도가 자연스럽게 줄지 않음")
        for index in 0..<240 {
            if index % 17 == 0 { motion.retarget(expanded: index % 34 == 0) }
            motion.advance(by: 1.0 / 120)
            try expect(motion.progress.isFinite && (0...1).contains(motion.progress), "빠른 반전 시 표시 범위를 벗어남")
        }
        motion.retarget(expanded: false)
        motion.advance(by: 1)
        try expect(motion.isSettled && motion.progress == 0, "접힌 크기로 마무리되지 않음")
        motion.retarget(expanded: true)
        motion.advance(by: 1)
        try expect(motion.isSettled && motion.progress == 1, "펼친 크기로 마무리되지 않음")

        motion.snap(expanded: false)
        motion.advance(by: .nan)
        motion.advance(by: -1)
        try expect(motion.progress == 0 && motion.velocity == 0, "동작 줄이기 또는 비정상 시간 처리 실패")
    }
}
