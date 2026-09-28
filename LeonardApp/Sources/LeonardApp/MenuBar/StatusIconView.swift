import AppKit
import LeonardCore

/// The menu bar mark: Leonard's glasses, in the menu bar's own color. The
/// eyes say what Leonard is doing — up while it watches, glancing side to
/// side while it thinks, down towards the card when it speaks, closed when
/// paused — and a small amber dot means something is waiting for you. No
/// badge counts, no bounce: a colleague getting your attention taps your
/// shoulder once, it does not flash.
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

        let glyph = bounds.insetBy(dx: 1, dy: (bounds.height - 9.5) / 2)
        let color = NSColor.labelColor
        switch activityState {
        case .disconnected:
            Glasses.draw(in: glyph, eyes: .none, color: color.withAlphaComponent(0.45))
        case .starting, .setupNeeded:
            Glasses.draw(in: glyph, eyes: .up, color: color.withAlphaComponent(0.55))
        case .paused:
            Glasses.draw(in: glyph, eyes: .closed, color: color.withAlphaComponent(0.6))
        case .watching:
            Glasses.draw(in: glyph, eyes: .up, color: color.withAlphaComponent(watching ? 1 : 0.5))
        case .thinking:
            // A slow glance from side to side, still looking up.
            let dx = sin(pulsePhase * 2 * .pi * 0.8)
            Glasses.draw(in: glyph, eyes: .look(CGVector(dx: dx, dy: -0.6)), color: color)
        case .suggesting:
            Glasses.draw(in: glyph, eyes: .look(CGVector(dx: -0.4, dy: 0.9)), color: color)
        case .waitingForYou:
            Glasses.draw(in: glyph, eyes: .up, color: color)
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 6, y: bounds.maxY - 7, width: 5, height: 5))
            NSColor.systemOrange.setFill()
            dot.fill()
        }
    }
}
