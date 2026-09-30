import AppKit
import SwiftUI
import LeonardCore

/// Leonard's visual language: native, quiet, one accent. Indigo for
/// Leonard's own voice, amber for "something needs you", red only for a
/// near-miss in Mind. Everything else is the system's.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.36, blue: 0.84)
    static let attention = Color(red: 0.96, green: 0.63, blue: 0.14)
    static let nearMiss = Color.red
    static let calm = Color.secondary

    static let corner: CGFloat = 18
    static let smallCorner: CGFloat = 10

    static func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .bobbGlass(radius: 20, tint: color.opacity(0.12))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .bobbGlass(radius: 20, tint: Theme.accent.opacity(configuration.isPressed ? 0.3 : 0.16), interactive: true)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .bobbGlass(radius: 18, interactive: true)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// A warning chip for a fact the model may have invented.
struct CheckChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(Theme.attention)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .bobbGlass(radius: 20, tint: Theme.attention.opacity(0.12))
    }
}

/// A horizontal wrap of chips, for sources and fact checks.
struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) { content() }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension SourceRef {
    var label: String {
        let where_ = window.isEmpty ? app : "\(app) · \(window)"
        return "[\(n)] \(where_)"
    }
}

/// Opens an app window without making Leonard a dock app.
@MainActor
enum WindowPresenter {
    static func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func makeWindow<Content: View>(title: String, size: NSSize, resizable: Bool = true, content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = NSHostingView(rootView: content.bobbWindowStyle())
        window.center()
        return window
    }
}
