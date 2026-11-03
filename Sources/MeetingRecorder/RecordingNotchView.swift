import AppKit
import SwiftUI

/// App-owned recording controls arranged around, but never under, a Mac notch.
struct RecordingNotchView: View {
    @ObservedObject var state: RecordingIslandState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { state.panelWidth }
    private var height: CGFloat { state.expanded ? 148 : 48 }
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
            if state.expanded {
                expandedContent
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .background(NotchBackdrop().fill(Color.black))
        .contentShape(NotchBackdrop())
        .onHover { state.hoverChanged?($0) }
        .accessibilityElement(children: .contain)
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
            Button(action: { state.start?() }) {
                controlLabel(symbol: state.canStart ? "record.circle" : "gearshape", title: state.canStart ? "시작" : "설정")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.canStart ? "녹음 시작" : "녹음 설정 확인")
            .accessibilityHint(state.canStart ? "녹음을 시작합니다" : "녹음 설정을 확인합니다")
            .help(state.canStart ? "녹음 시작" : "녹음 설정 확인")
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(phaseText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !state.targetName.isEmpty {
                    Text(state.targetName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                Text(state.phase == .recording ? state.elapsed : detailText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .accessibilityLabel(state.phase == .recording ? "경과 시간 \(state.elapsed)" : detailText)
            }
            Spacer(minLength: 0)
            if state.phase == .recording || state.phase == .preparing {
                Button(action: { state.stop?() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        Text(state.phase == .recording ? "종료" : "취소")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.phase == .recording ? "녹음 종료" : "녹음 준비 취소")
                .help(state.phase == .recording ? "녹음을 종료하고 저장합니다" : "녹음 준비를 취소합니다")
            } else if state.phase == .idle || state.phase == .ended {
                Button(action: { state.start?() }) {
                    HStack(spacing: 6) {
                        Image(systemName: state.canStart ? "record.circle" : "gearshape").font(.system(size: 11, weight: .bold))
                        Text(state.canStart ? "시작" : "설정").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.canStart ? "녹음 시작" : "녹음 설정 확인")
                .accessibilityHint(state.canStart ? "녹음을 시작합니다" : "녹음 설정을 확인합니다")
            } else if state.phase == .stopping {
                ProgressView().controlSize(.small).tint(.white)
                    .accessibilityLabel("녹음 저장 중")
            }
        }
        .padding(.horizontal, 21)
        .frame(width: width, height: 100)
    }

    private var detailText: String {
        switch state.phase {
        case .idle: return state.canStart ? "녹음을 시작할 수 있습니다" : "시작하려면 설정을 확인해 주세요"
        case .preparing: return "준비 중"
        case .recording: return state.elapsed
        case .stopping: return "잠시만 기다려 주세요"
        case .ended: return "녹음이 종료되었습니다"
        }
    }
}

private struct NotchBackdrop: InsettableShape {
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.inset += amount
        return copy
    }
    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let radius = min(20, bounds.height / 2, bounds.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY), control: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.addQuadCurve(to: CGPoint(x: bounds.minX, y: bounds.maxY - radius), control: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.closeSubpath()
        return path
    }
}
