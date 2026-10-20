import AppKit
import SwiftUI

/// The folder's colour: it tints the glass of the open folder and of its Dock icon.
/// Saved by name, or as #RRGGBB for a colour of the user's own. Anything this version
/// doesn't understand falls back to clear glass.
enum FolderTint: Hashable, Identifiable {
    case clear, blue, purple, pink, red, orange, yellow, green, teal, graphite
    /// Any colour, picked in the colour panel. sRGB components from 0 to 1.
    case custom(red: Double, green: Double, blue: Double)

    /// The ready-made colours, in the order the picker shows them.
    static let presets: [FolderTint] = [.clear, .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .graphite]

    init(savedName: String?) {
        guard let savedName else {
            self = .clear
            return
        }
        self = Self.presets.first { $0.savedName == savedName } ?? Self.custom(hex: savedName) ?? .clear
    }

    /// A colour of the user's own, rounded to what the file keeps, so the picker and the file agree.
    init(color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> Double { (Double(min(max(value, 0), 1)) * 255).rounded() / 255 }
        self = .custom(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
    }

    var id: String { savedName }

    /// How the colour is written to the folder's file.
    var savedName: String {
        switch self {
        case .clear: return "clear"
        case .blue: return "blue"
        case .purple: return "purple"
        case .pink: return "pink"
        case .red: return "red"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .teal: return "teal"
        case .graphite: return "graphite"
        case .custom(let red, let green, let blue):
            return String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
                          Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var title: String { isCustom ? "Custom (\(savedName))" : savedName.capitalized }

    var nsColor: NSColor? {
        switch self {
        case .clear: return nil
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .graphite: return .systemGray
        case .custom(let red, let green, let blue):
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    var color: Color? { nsColor.map { Color(nsColor: $0) } }

    /// The tint as applied to glass: strong enough to read as a colour, light enough to stay glass.
    var glassColor: Color? { color?.opacity(0.35) }

    private static func custom(hex: String) -> FolderTint? {
        let digits = hex.dropFirst()
        guard hex.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isHexDigit),
              let value = Int(digits, radix: 16) else { return nil }
        return .custom(red: Double((value >> 16) & 0xFF) / 255,
                       green: Double((value >> 8) & 0xFF) / 255,
                       blue: Double(value & 0xFF) / 255)
    }
}
