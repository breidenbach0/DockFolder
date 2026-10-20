import AppKit
import SwiftUI

/// The ready-made colours as swatches, like the accent colours in System Settings, then a
/// rainbow well that opens the colour panel for any colour at all.
struct TintPicker: View {
    @Binding var selection: FolderTint
    @StateObject private var colorPanel = ColorPanelLink()

    var body: some View {
        HStack(spacing: 7) {
            ForEach(FolderTint.presets) { tint in
                Button { selection = tint } label: {
                    TintSwatch(fill: tint.color.map(TintSwatch.Fill.color) ?? .clearGlass, isSelected: tint == selection)
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.85))
                .help(tint.title)
                .accessibilityLabel(tint.title)
                .accessibilityAddTraits(tint == selection ? .isSelected : [])
            }
            customColorWell
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selection)
        .onDisappear { colorPanel.detach() }
    }

    private var customColorWell: some View {
        let custom = selection.isCustom ? selection : nil
        return Button {
            // Start from the colour in use, so a ready-made one can be nudged.
            colorPanel.open(color: selection.nsColor ?? .systemIndigo) { color in
                selection = FolderTint(color: color)
            }
        } label: {
            TintSwatch(fill: .rainbow(center: custom?.color), isSelected: custom != nil)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.85))
        .help(custom.map { "\($0.title). Click to change it." } ?? "Any colour you like")
        .accessibilityLabel(custom?.title ?? "Custom colour")
        .accessibilityAddTraits(custom != nil ? .isSelected : [])
    }
}

private struct TintSwatch: View {
    enum Fill {
        case clearGlass
        case color(Color)
        /// The custom colour well: a colour wheel, with the colour in use in the middle.
        case rainbow(center: Color?)
    }

    let fill: Fill
    let isSelected: Bool

    var body: some View {
        ZStack {
            switch fill {
            case .clearGlass:
                Circle().fill(.ultraThinMaterial)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            case .color(let color):
                Circle().fill(color.gradient)
            case .rainbow(let center):
                Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .mint, .blue, .purple, .pink, .red],
                                              center: .center))
                if let center {
                    Circle().fill(center.gradient).padding(4.5)
                }
            }
            Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: .black.opacity(0.25), radius: 1)
            }
        }
        .frame(width: 22, height: 22)
        .padding(3)
        .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.55 : 0), lineWidth: 1.5))
        .contentShape(Circle())
    }
}

/// Connects the shared macOS colour panel to one picker at a time.
@MainActor
final class ColorPanelLink: NSObject, ObservableObject {
    private static weak var attached: ColorPanelLink?
    private var onChange: ((NSColor) -> Void)?
    private var pendingColor: NSColor?
    private var lastDelivery = Date.distantPast

    func open(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.setTarget(nil)   // so setting the colour below reaches no one
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        Self.attached = self
        panel.makeKeyAndOrderFront(nil)
    }

    /// When the picker goes away, its colour panel goes too, rather than changing nothing.
    func detach() {
        guard Self.attached === self, NSColorPanel.sharedColorPanelExists else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        Self.attached = nil
    }

    /// The panel reports every step of a drag. Pass on at most one colour every 0.15 s, and
    /// always the last, so the folder isn't saved and redrawn dozens of times a second.
    @objc private func colorDidChange(_ panel: NSColorPanel) {
        pendingColor = panel.color
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deliver), object: nil)
        let wait = 0.15 - Date().timeIntervalSince(lastDelivery)
        if wait <= 0 {
            deliver()
        } else {
            perform(#selector(deliver), with: nil, afterDelay: wait)
        }
    }

    @objc private func deliver() {
        guard let color = pendingColor else { return }
        pendingColor = nil
        lastDelivery = Date()
        onChange?(color)
    }
}
