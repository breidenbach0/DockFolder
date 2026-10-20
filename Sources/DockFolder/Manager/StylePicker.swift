import SwiftUI

/// Pages or the grid, as two small drawings to pick from, like the choices in System Settings.
struct StylePicker: View {
    @Binding var selection: FolderStyle
    /// Apps in the folder. A layout with less room than that can't be picked.
    let appCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(FolderStyle.allCases) { style in
                let fits = appCount <= style.capacity
                let isSelected = style == selection
                let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
                Button { selection = style } label: {
                    VStack(spacing: 5) {
                        StyleThumbnail(style: style)
                            .frame(width: 96, height: 66)
                            .background(card.fill(Color.primary.opacity(0.06)))
                            .overlay(card.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                                       lineWidth: isSelected ? 2.5 : 1))
                        Text(style.title)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                        Text(style.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 128)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
                .disabled(!fits)
                .opacity(fits ? 1 : 0.45)
                .help(fits ? style.summary : "Holds up to \(style.capacity) apps. Remove \(appCount - style.capacity) to switch.")
                .accessibilityLabel("\(style.title), \(style.summary)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A tiny drawing of a layout: a 3 × 3 page with its page dots, or a 6 × 6 grid.
private struct StyleThumbnail: View {
    let style: FolderStyle

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .indigo, .red]

    var body: some View {
        switch style {
        case .pages:
            VStack(spacing: 5) {
                squares(columns: 3, rows: 3, size: 11)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.primary.opacity(index == 0 ? 0.7 : 0.25))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        case .grid:
            squares(columns: 6, rows: 6, size: 7)
        }
    }

    private func squares(columns: Int, rows: Int, size: CGFloat) -> some View {
        VStack(spacing: size * 0.35) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: size * 0.35) {
                    ForEach(0..<columns, id: \.self) { column in
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .fill(Self.colors[(row * columns + column) % Self.colors.count].gradient)
                            .frame(width: size, height: size)
                    }
                }
            }
        }
    }
}
