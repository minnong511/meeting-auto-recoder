import AppKit
import SwiftUI

/// App-owned recording controls arranged around, but never under, a Mac notch.
struct RecordingNotchView: View {
    @ObservedObject var state: RecordingIslandState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { state.panelWidth }
    private var notchSpace: CGFloat { state.hasNotch ? min(max(state.notchWidth, 0), width) : 0 }
    private var sideWidth: CGFloat { max(0, (width - notchSpace) / 2) }
    private var phaseText: String {
        switch state.phase {
        case .idle: return "녹음 대기"
        case .preparing: return "녹음 준비 중"
        case .recording: return "녹음 중"
        case .stopping: return "녹음 저장 중"
        case .ended: return "녹음 종료"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            topStrip
            // Keep the layout mounted; one display-synchronized progress drives
            // the window's reveal and this content instead of two animations.
            expandedContent
                .opacity(state.expansionProgress)
                .offset(y: -6 * (1 - state.expansionProgress))
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)
        }
        // This host has a constant size and is clipped by the resizing AppKit
        // container. Its top row therefore never moves while the panel grows.
        .frame(width: width, height: 148, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .onHover { state.hoverChanged?($0) }
        .accessibilityElement(children: .contain)
        .ignoresSafeArea()
    }

    private var statusColor: Color {
        switch state.phase {
        case .recording: return Color(red: 1, green: 0.25, blue: 0.28)
        case .preparing, .stopping: return Color.white.opacity(0.7)
        case .idle, .ended: return Color.white.opacity(0.45)
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .idle: return "대기"
        case .preparing: return "준비 중"
        case .recording: return "녹음 중"
        case .stopping: return "저장 중"
        case .ended: return "종료"
        }
    }

    private var topStrip: some View {
        HStack(spacing: 0) {
            Button(action: { state.toggleExpanded?() }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.phase)
                    if sideWidth >= 80 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(statusLabel)
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.phase)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if state.phase == .recording {
                                Text(state.elapsed)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, sideWidth >= 80 ? 12 : 4)
                .frame(width: sideWidth, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.phase == .recording ? "녹음 중, 경과 시간 \(state.elapsed)" : phaseText)
            .accessibilityHint(state.expanded ? "녹음 제어 접기" : "녹음 제어 펼치기")
            .clipped()

            if state.hasNotch {
                Color.clear.frame(width: notchSpace, height: 48).accessibilityHidden(true)
            }

            HStack {
                Spacer(minLength: 0)
                compactControl
            }
            .padding(.trailing, sideWidth >= 80 ? 12 : 4)
            .frame(width: sideWidth, height: 48)
            .clipped()
        }
        .frame(width: width, height: 48)
    }

    @ViewBuilder
    private var compactControl: some View {
        switch state.phase {
        case .idle, .ended:
            Text(state.elapsed)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
                .accessibilityLabel("경과 시간 \(state.elapsed)")
        case .preparing, .recording:
            Button(action: { state.stop?() }) {
                controlLabel(symbol: "stop.fill", title: state.phase == .recording ? "정지" : "취소")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.phase == .recording ? "녹음 정지" : "녹음 준비 취소")
            .help(state.phase == .recording ? "녹음을 정지하고 저장합니다" : "녹음 준비를 취소합니다")
        case .stopping:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(width: min(40, sideWidth), height: 36)
                .accessibilityLabel("녹음 저장 중")
        }
    }

    private func controlLabel(symbol: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            if sideWidth >= 80 {
                Text(title).font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: min(sideWidth, sideWidth >= 80 ? 64 : 32), height: 32)
        .background(Color.white.opacity(0.15), in: Capsule())
        .contentShape(Capsule())
    }

    private var expandedContent: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text(state.elapsed)
                    .font(.system(size: 27, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityLabel("경과 시간 \(state.elapsed)")
                Text(phaseText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(state.targetName.isEmpty || state.phase == .idle ? detailText : state.targetName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if state.phase == .recording {
                        Text("입력 음량").fixedSize()
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))

                GeometryReader { geometry in
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(state.levels.indices, id: \.self) { index in
                            Capsule()
                                .fill(state.phase == .recording ? statusColor : Color.white.opacity(0.2))
                                .frame(width: max(1, (geometry.size.width - CGFloat(state.levels.count - 1) * 3) / CGFloat(state.levels.count)),
                                       height: max(2, CGFloat(state.levels[index]) * geometry.size.height))
                        }
                    }
                    .frame(height: geometry.size.height)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: state.levels)
                }
                .frame(height: 36)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("녹음 입력 음량")
                .accessibilityValue("\(Int((state.levels.last ?? 0) * 100)) 퍼센트")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 21)
        .frame(width: width, height: 100)
    }

    private var detailText: String {
        switch state.phase {
        case .idle: return "앱에서 녹음을 시작하세요"
        case .preparing: return "준비 중"
        case .recording: return state.elapsed
        case .stopping: return "잠시만 기다려 주세요"
        case .ended: return "녹음이 종료되었습니다"
        }
    }
}
