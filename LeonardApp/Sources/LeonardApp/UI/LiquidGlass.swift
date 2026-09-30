import AppKit
import SwiftUI

/// Native Liquid Glass on Tahoe; the same layout uses system vibrancy on
/// earlier Macs. Accessibility settings always take precedence.
private struct BobbGlassSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                if interactive {
                    content.glassEffect(.regular.tint(tint).interactive(), in: RoundedRectangle(cornerRadius: radius))
                } else {
                    content.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius))
                }
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
    }
}

struct BobbGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12, content: content)
        } else { content() }
        #else
        content()
        #endif
    }
}

struct BobbWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct BobbWindowStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.tint(Theme.accent)
            .buttonStyle(QuietButtonStyle())
            .groupBoxStyle(BobbGroupBoxStyle())
            .background {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else {
                    BobbWindowBackdrop()
                    LinearGradient(colors: [Theme.accent.opacity(0.08), .clear, .cyan.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
    }
}

struct BobbGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

extension View {
    func bobbGlass(radius: CGFloat = Theme.corner, tint: Color = .clear, interactive: Bool = false) -> some View {
        modifier(BobbGlassSurface(radius: radius, tint: tint, interactive: interactive))
    }
    func bobbWindowStyle() -> some View { modifier(BobbWindowStyle()) }
}
