import SwiftUI

enum SigmaTheme {
    static let paper = Color(red: 0.976, green: 0.973, blue: 0.953)
    static let surface = Color(red: 0.996, green: 0.995, blue: 0.990)
    static let ink = Color(red: 0.120, green: 0.120, blue: 0.110)
    static let secondary = Color(red: 0.372, green: 0.364, blue: 0.340)
    static let hairline = Color(red: 0.842, green: 0.836, blue: 0.806)

    static let stageInsetH: CGFloat = 12
    static let stageInsetV: CGFloat = 16

    static let contentTopInset: CGFloat = 8

    /// Trailing develop column width on wide iOS layouts
    static let developSidebarWidth: CGFloat = 340

    /// Shared spring for rail collapse/expand and tray detents
    static let panelSpring = Animation.spring(response: 0.38, dampingFraction: 0.88)
}

#if os(iOS)
extension CGSize {
    /// Pin develop to a trailing rail when there is room for stage + column
    /// (macOS always hosts develop in the native inspector instead).
    var prefersDevelopRail: Bool {
        width >= 640 && width > height
    }
}
#endif

extension View {
    func sigmaLabel(size: CGFloat = 11, color: Color = SigmaTheme.secondary, tracking: CGFloat = 1.3) -> some View {
        font(.system(size: size, weight: .medium, design: .default))
            .textCase(.uppercase)
            .tracking(tracking)
            .foregroundStyle(color)
    }

    func sigmaText(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> some View {
        font(.system(style, design: .serif).weight(weight))
    }

    func sigmaBackground() -> some View {
        background(SigmaTheme.paper.ignoresSafeArea())
    }
}
