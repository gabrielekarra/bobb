import AppKit
import LeonardCore

/// A quiet, hand-drawn 18×18 glyph: a ring that fills to different degrees
/// and colors for each `ActivityState`. `waitingForYou` adds a small amber
/// dot, like an unread badge that does not shout.
/// No template image, no badge, no bounce — the icon should read as calm
/// even in `suggesting`, because a colleague getting your attention taps
/// your shoulder once, it does not flash.
final class StatusIconView: NSView {
    var activityState: ActivityState = .disconnected {
        didSet { if oldValue != activityState { needsDisplay = true } }
    }
    var watching: Bool = true {
        didSet { if oldValue != watching { needsDisplay = true } }
    }

    private var pulsePhase: Double = 0
    private var pulseTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopPulsing() : syncPulsing()
    }

    private func syncPulsing() {
        if activityState == .thinking {
            startPulsing()
        } else {
            stopPulsing()
        }
    }

    private func startPulsing() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pulsePhase += 1.0 / 24.0
                self.needsDisplay = true
            }
        }
        if let pulseTimer { RunLoop.main.add(pulseTimer, forMode: .common) }
    }

    private func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        syncPulsing()

        let diameter: CGFloat = 9
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter, height: diameter
        )
        let ring = NSBezierPath(ovalIn: rect)

        let color = tintColor()
        switch activityState {
        case .disconnected, .starting, .setupNeeded:
            color.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 1.2
            ring.stroke()
        case .paused:
            color.withAlphaComponent(0.35).setStroke()
            ring.lineWidth = 1.2
            ring.stroke()
        case .watching:
            color.withAlphaComponent(watching ? 0.9 : 0.35).setFill()
            ring.fill()
        case .thinking:
            let alpha = 0.55 + 0.35 * sin(pulsePhase * 2 * .pi)
            color.withAlphaComponent(alpha).setFill()
            ring.fill()
        case .suggesting:
            color.setFill()
            ring.fill()
        case .waitingForYou:
            NSColor.labelColor.withAlphaComponent(0.9).setFill()
            ring.fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.maxX - 2, y: rect.maxY - 3, width: 5, height: 5))
            NSColor.systemOrange.setFill()
            dot.fill()
        }
    }

    private func tintColor() -> NSColor {
        switch activityState {
        case .disconnected, .paused: .secondaryLabelColor
        case .starting, .setupNeeded: .systemOrange
        case .watching, .waitingForYou: .labelColor
        case .thinking: .systemIndigo
        case .suggesting: .systemOrange
        }
    }
}
