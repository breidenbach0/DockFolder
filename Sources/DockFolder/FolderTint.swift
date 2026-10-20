import AppKit
import SwiftUI

/// The folder's colour: it tints the glass of the open folder and of its Dock icon.
/// Saved by name, so a name this version doesn't know falls back to clear glass.
enum FolderTint: String, CaseIterable, Identifiable {
    case clear, blue, purple, pink, red, orange, yellow, green, teal, graphite

    init(savedName: String?) {
        self = savedName.flatMap(FolderTint.init(rawValue:)) ?? .clear
    }

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

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
        }
    }

    var color: Color? { nsColor.map { Color(nsColor: $0) } }

    /// The tint as applied to glass: strong enough to read as a colour, light enough to stay glass.
    var glassColor: Color? { color?.opacity(0.35) }
}
