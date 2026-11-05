import AppKit
import CoreText
import SwiftUI

enum RecorderTheme {
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
    static let canvas = adaptive("RecorderCanvas", light: 0xFAFBFC, dark: 0x17191C)
    static let sidebar = adaptive("RecorderSidebar", light: 0xF0F2F5, dark: 0x202226)
    static let surface = adaptive("RecorderSurface", light: 0xFFFFFF, dark: 0x22252A)
    static let border = adaptive("RecorderBorder", light: 0xDFE3E8, dark: 0x363A42)
    static let hover = adaptive("RecorderHover", light: 0xE6E9EE, dark: 0x2D3138)
    static let accent = adaptive("RecorderAccent", light: 0x0F766E, dark: 0x65C8B9)
    static let onAccent = adaptive("RecorderOnAccent", light: 0xFFFFFF, dark: 0x102C28)
    static let recording = adaptive("RecorderRecording", light: 0xDC2626, dark: 0xF87171)
    static let contentWidth: CGFloat = 760
    static func body(_ size: CGFloat = 15) -> Font { .custom("PretendardVariable-Regular", size: size) }
    static func heading(_ size: CGFloat) -> Font { .custom("PretendardVariable-SemiBold", size: size) }

    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "PretendardVariable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

struct QuietHover: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.background(hovering ? RecorderTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
            .onHover { value in withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { hovering = value } }
    }
}

/// Keep the label readable even when the Mac window is inactive. Native
/// prominent buttons replace their fill in that state, so a fixed label color
/// alone cannot guarantee contrast.
struct RecorderPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(isEnabled ? RecorderTheme.onAccent : Color.secondary)
            .background(isEnabled ? RecorderTheme.accent.opacity(configuration.isPressed ? 0.85 : 1) : RecorderTheme.hover,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

enum LibraryDate {
    static func string(_ date: Date, includesYear: Bool = false) -> String {
        if includesYear {
            return date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ko_KR")))
        }
        return date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "ko_KR")))
    }
}
