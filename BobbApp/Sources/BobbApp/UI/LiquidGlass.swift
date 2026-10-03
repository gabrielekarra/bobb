import AppKit
import SwiftUI

/// Floating surfaces own a native glass view containing their SwiftUI host.
/// Keeping the host inside contentView lets AppKit compose the actual glass
/// against the desktop, without an opaque hosting background covering it.
@MainActor
final class BobbGlassHostingView: NSView {
    let hosted: NSView
    private let radius: CGFloat
    private let clearGlass: Bool
    private var surface: NSView?

    init(_ hosted: NSView, radius: CGFloat = 24, clear: Bool = true) {
        self.hosted = hosted; self.radius = radius; self.clearGlass = clear
        super.init(frame: NSRect(origin: .zero, size: hosted.fittingSize))
        autoresizingMask = [.width, .height]
        rebuild()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(rebuild),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var fittingSize: NSSize { hosted.fittingSize }
    override var intrinsicContentSize: NSSize { hosted.intrinsicContentSize }
    override func layout() {
        super.layout(); surface?.frame = bounds; hosted.frame = bounds
    }
    @objc private func rebuild() {
        hosted.removeFromSuperview(); surface?.removeFromSuperview()
        let next: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let opaque = NSView(frame: bounds)
            opaque.wantsLayer = true; opaque.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            opaque.layer?.cornerRadius = radius; opaque.addSubview(hosted); next = opaque
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.cornerRadius = radius; glass.style = clearGlass ? .clear : .regular
                glass.contentView = hosted; next = glass
            } else { next = legacySurface() }
            #else
            next = legacySurface()
            #endif
        }
        hosted.autoresizingMask = [.width, .height]
        next.autoresizingMask = [.width, .height]
        surface = next; addSubview(next); needsLayout = true
    }
    private func legacySurface() -> NSView {
        let view = NSVisualEffectView(frame: bounds)
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.wantsLayer = true; view.layer?.cornerRadius = radius; view.layer?.masksToBounds = true
        view.addSubview(hosted); return view
    }
}

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

private struct BobbWindowStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.tint(Theme.accent)
            .buttonStyle(QuietButtonStyle())
            .groupBoxStyle(BobbGroupBoxStyle())
            .background {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else {
                    LinearGradient(colors: [Theme.accent.opacity(0.045), .clear, Theme.accent.opacity(0.02)],
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
        .bobbGlass(radius: Theme.corner)
    }
}

extension View {
    func bobbGlass(radius: CGFloat = Theme.corner, tint: Color = .clear, interactive: Bool = false) -> some View {
        modifier(BobbGlassSurface(radius: radius, tint: tint, interactive: interactive))
    }
    func bobbWindowStyle() -> some View { modifier(BobbWindowStyle()) }
}
