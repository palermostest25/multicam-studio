import SwiftUI

// Appearance: "Liquid Glass" (default) or "Classic" (the 2.0 look), switchable in Settings.
// Liquid Glass needs macOS 26; on macOS 14–15 it falls back to the nearest material look.

enum Appearance {
    static let key = "liquidGlass"
    static var supported: Bool { if #available(macOS 26.0, *) { true } else { false } }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    @AppStorage(Appearance.key) private var enabled = true
    let shape: S
    var interactive = false
    var tint: Color?
    var classic: AnyShapeStyle?   // what Classic mode draws instead (nil = nothing)

    func body(content: Content) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
                    .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 0.5))
            }
        } else if let classic {
            content.background(classic, in: shape)
        } else {
            content
        }
    }
}

private struct GlassButton: ViewModifier {
    @AppStorage(Appearance.key) private var enabled = true
    let prominent: Bool
    let classic: ClassicButton

    func body(content: Content) -> some View {
        if enabled, #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            switch classic {
            case .prominent: content.buttonStyle(.borderedProminent)
            case .bordered: content.buttonStyle(.bordered)
            case .borderless: content.buttonStyle(.borderless)
            }
        }
    }
}

enum ClassicButton { case prominent, bordered, borderless }

private struct GlassGroup: ViewModifier {
    @AppStorage(Appearance.key) private var enabled = true
    let spacing: CGFloat
    func body(content: Content) -> some View {
        if enabled, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// A glass surface behind this view; in Classic mode, `classic` (or nothing).
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil,
                                classic: AnyShapeStyle? = nil) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, tint: tint, classic: classic))
    }

    func glassCapsule(interactive: Bool = false, tint: Color? = nil, classic: AnyShapeStyle? = nil) -> some View {
        glassSurface(Capsule(), interactive: interactive, tint: tint, classic: classic)
    }

    /// Glass push buttons; Classic mode keeps the 2.0 button style given.
    func glassButton(prominent: Bool = false, classic: ClassicButton? = nil) -> some View {
        modifier(GlassButton(prominent: prominent, classic: classic ?? (prominent ? .prominent : .bordered)))
    }

    /// Lets neighbouring glass shapes blend and morph together.
    func glassGroup(spacing: CGFloat = 8) -> some View {
        modifier(GlassGroup(spacing: spacing))
    }
}
