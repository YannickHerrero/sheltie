import SheltieProtocol
import SwiftUI
import UIKit

enum SheltieTheme {
    static let background = Color(red: 0.882, green: 0.886, blue: 0.906)
    static let surface = Color(red: 0.847, green: 0.851, blue: 0.878)
    static let surfaceHigh = Color(red: 0.856, green: 0.860, blue: 0.886)
    static let foreground = Color(red: 0.122, green: 0.184, blue: 0.400)
    static let muted = Color(red: 0.408, green: 0.439, blue: 0.604)
    static let border = Color(red: 0.714, green: 0.733, blue: 0.820)
    static let accent = Color(red: 0.180, green: 0.490, blue: 0.914)
    static let success = Color(red: 0.345, green: 0.459, blue: 0.224)
    static let warning = Color(red: 0.549, green: 0.424, blue: 0.243)
    static let danger = Color(red: 0.961, green: 0.165, blue: 0.396)

    static let accentSoft = accent.opacity(0.13)
    static let foregroundSoft = foreground.opacity(0.07)

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Iowan Old Style", size: size, relativeTo: .title).weight(weight)
    }

    static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let uiBackground = UIColor(red: 0.882, green: 0.886, blue: 0.906, alpha: 1)
    static let uiForeground = UIColor(red: 0.122, green: 0.184, blue: 0.400, alpha: 1)
}

extension AgentStatus {
    var sheltieColor: Color {
        switch self {
        case .working: SheltieTheme.warning
        case .blocked: SheltieTheme.danger
        case .done: SheltieTheme.success
        case .idle, .unknown: SheltieTheme.muted
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.sheltieColor)
            .frame(width: size, height: size)
            .background(Circle().fill(status.sheltieColor.opacity(0.12)).padding(-4))
            .accessibilityLabel(status.accessibilityDescription)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(SheltieTheme.border).frame(height: 1)
    }
}
