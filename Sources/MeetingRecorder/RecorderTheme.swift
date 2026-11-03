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
    static let canvas = adaptive("RecorderCanvas", light: 0xF9F9F9, dark: 0x171717)
    static let sidebar = adaptive("RecorderSidebar", light: 0xF4F4F4, dark: 0x202020)
    static let surface = adaptive("RecorderSurface", light: 0xFFFFFF, dark: 0x1C1C1C)
    static let border = adaptive("RecorderBorder", light: 0xE5E5E5, dark: 0x3B3B3B)
    static let hover = adaptive("RecorderHover", light: 0xEEEEEE, dark: 0x303030)
    static let accent = adaptive("RecorderAccent", light: 0x0F766E, dark: 0x65C8B9)
    static let recording = adaptive("RecorderRecording", light: 0xDC2626, dark: 0xF87171)
    static let contentWidth: CGFloat = 760
    static func body(_ size: CGFloat = 14) -> Font { .custom("PretendardVariable-Regular", size: size) }
    static func heading(_ size: CGFloat) -> Font { .custom("PretendardVariable-SemiBold", size: size) }

    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "PretendardVariable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

struct QuietHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(hovering ? RecorderTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
            .onHover { value in withAnimation(.easeInOut(duration: 0.18)) { hovering = value } }
    }
}
