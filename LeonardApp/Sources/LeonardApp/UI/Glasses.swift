import AppKit
import SwiftUI

/// Leonard's mark: a pair of round glasses whose eyes look up. One geometry,
/// in unit coordinates, drawn by the menu bar icon, the interface, and
/// `scripts/make_icon.py` for the app icon — keep the constants in sync.
///
/// The eyes carry state: they look up while Leonard watches, glance around
/// while it thinks, look down towards the card when it speaks, and close when
/// it is paused.
enum Glasses {
    /// The glyph's height as a fraction of its width.
    static let aspect: CGFloat = 0.46
    static let lensRadius: CGFloat = 0.2
    static let lensDX: CGFloat = 0.255
    static let lensY: CGFloat = 0.25
    static let pupilRadius: CGFloat = 0.078
    static let pupilTravel: CGFloat = 0.088
    static let line: CGFloat = 0.05
    static let bridgeLift: CGFloat = 0.045
    static let bridgeDegrees: CGFloat = 28
    static let templeDegrees: CGFloat = 22
    static let temple = CGSize(width: 0.05, height: 0.035)

    enum Eyes: Equatable {
        /// Pupils offset by a unit vector; y points down, so `(0, -1)` looks up.
        case look(CGVector)
        case closed
        case none

        static let up = Eyes.look(CGVector(dx: 0, dy: -1))
    }

    struct Paths {
        /// Lenses, bridge and temples, to be stroked with `lineWidth`.
        var frame: CGPath
        /// Pupils (filled) or closed eyelids (stroked), per `eyes`.
        var eyes: CGPath
        var eyesAreStroked: Bool
        var lineWidth: CGFloat
    }

    /// The glyph fitted to `rect`, centered. `flipped` is true for y-down
    /// contexts (SwiftUI), false for AppKit's default y-up views.
    static func paths(in rect: CGRect, eyes: Eyes, flipped: Bool, minimumLine: CGFloat = 0) -> Paths {
        let width = min(rect.width, rect.height / aspect)
        let origin = CGPoint(x: rect.midX - width / 2, y: rect.midY - width * aspect / 2)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let py = flipped ? y : aspect - y
            return CGPoint(x: origin.x + x * width, y: origin.y + py * width)
        }
        func onLens(_ cx: CGFloat, _ degrees: CGFloat) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: cx + lensRadius * cos(a), y: lensY - lensRadius * sin(a))
        }

        let lineWidth = max(minimumLine, line * width)
        let frame = CGMutablePath()
        let left = 0.5 - lensDX, right = 0.5 + lensDX
        for cx in [left, right] {
            let c = P(cx, lensY)
            frame.addEllipse(in: CGRect(x: c.x - lensRadius * width, y: c.y - lensRadius * width,
                                        width: 2 * lensRadius * width, height: 2 * lensRadius * width))
        }
        for (cx, degrees, side) in [(left, 180 - templeDegrees, CGFloat(-1)), (right, templeDegrees, CGFloat(1))] {
            let start = onLens(cx, degrees)
            frame.move(to: P(start.x, start.y))
            frame.addLine(to: P(start.x + side * temple.width, start.y - temple.height))
        }
        let a = onLens(left, bridgeDegrees)
        let b = onLens(right, 180 - bridgeDegrees)
        frame.move(to: P(a.x, a.y))
        frame.addQuadCurve(to: P(b.x, b.y), control: P(0.5, a.y - 2 * bridgeLift))

        let eyePath = CGMutablePath()
        var stroked = false
        switch eyes {
        case .look(let v):
            let length = max(1, (v.dx * v.dx + v.dy * v.dy).squareRoot())
            let dx = v.dx / length, dy = v.dy / length
            for cx in [left, right] {
                let c = P(cx + dx * pupilTravel, lensY + dy * pupilTravel)
                let r = pupilRadius * width
                eyePath.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        case .closed:
            stroked = true
            for cx in [left, right] {
                let span = lensRadius * 0.55
                eyePath.move(to: P(cx - span, lensY + 0.01))
                eyePath.addQuadCurve(to: P(cx + span, lensY + 0.01), control: P(cx, lensY + 0.07))
            }
        case .none:
            break
        }
        return Paths(frame: frame, eyes: eyePath, eyesAreStroked: stroked, lineWidth: lineWidth)
    }

    /// Draws into the current AppKit graphics context.
    static func draw(in rect: CGRect, eyes: Eyes, color: NSColor, eyeColor: NSColor? = nil, minimumLine: CGFloat = 1.1) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paths = paths(in: rect, eyes: eyes, flipped: false, minimumLine: minimumLine)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(paths.lineWidth)
        context.setStrokeColor(color.cgColor)
        context.addPath(paths.frame)
        context.strokePath()
        let eyeColor = (eyeColor ?? color).cgColor
        context.addPath(paths.eyes)
        if paths.eyesAreStroked {
            context.setStrokeColor(eyeColor)
            context.strokePath()
        } else {
            context.setFillColor(eyeColor)
            context.fillPath()
        }
        context.restoreGState()
    }
}

/// The mark in SwiftUI. `size` is the glyph's width.
struct LeonardMark: View {
    var size: CGFloat = 18
    var color: Color = .primary
    var eyes: Glasses.Eyes = .up

    var body: some View {
        Canvas { context, canvasSize in
            let paths = Glasses.paths(in: CGRect(origin: .zero, size: canvasSize), eyes: eyes, flipped: true, minimumLine: 1.1)
            let style = StrokeStyle(lineWidth: paths.lineWidth, lineCap: .round)
            context.stroke(Path(paths.frame), with: .color(color), style: style)
            if paths.eyesAreStroked {
                context.stroke(Path(paths.eyes), with: .color(color), style: style)
            } else {
                context.fill(Path(paths.eyes), with: .color(color))
            }
        }
        .frame(width: size, height: size * Glasses.aspect)
        .accessibilityHidden(true)
    }
}

/// The app icon as it appears in the Dock, for onboarding and About.
struct LeonardAppIcon: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
