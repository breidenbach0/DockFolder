import SwiftUI

// Liquid Glass arrived in macOS 26. These helpers use it there and fall back to the
// older blur materials on macOS 13–15, so the rest of the code doesn't need availability checks.

extension View {
    /// Puts the view on glass in the given shape, optionally tinted.
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.4)) }
                }
            }
        }
    }

    /// Glass buttons on macOS 26 and later; bordered buttons before that.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Shrinks a little while pressed, like an app icon on iPhone.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A small round button for use on glass: a soft fill that brightens on hover.
struct CircleIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        CircleIconButton(configuration: configuration, diameter: diameter)
    }

    private struct CircleIconButton: View {
        let configuration: ButtonStyleConfiguration
        let diameter: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : isHovered ? 0.14 : 0.08)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}
