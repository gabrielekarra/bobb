import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

/// "Through the accessibility tree first and the screen when it must"
/// (PRODUCT.md): for windows that expose no text — a scanned PDF, a canvas,
/// a remote desktop, an image — Leonard can read the words in the pixels
/// with Apple's on-device text recognition. Only the text is kept; the
/// image is never stored or sent. Off unless the user turns it on, and it
/// needs the Screen Recording permission, which macOS asks for.
@MainActor
enum ScreenTextRecognizer {
    struct Control: Sendable, Equatable {
        var text: String
        var frame: CGRect
    }
    struct Readout: Sendable {
        var controls: [Control]
        var text: String { controls.map(\.text).joined(separator: "\n") }
    }
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// The text visible in the front window of `pid`, top to bottom.
    static func read(pid: pid_t, windowTitle: String) async -> String? {
        await readout(pid: pid, windowTitle: windowTitle)?.text
    }

    static func readout(pid: pid_t, windowTitle: String) async -> Readout? {
        guard isAllowed else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 200 }
        guard let window = candidates.first(where: { $0.title == windowTitle }) ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return await recognizeControls(image, windowFrame: window.frame)
    }

    private nonisolated static func recognizeControls(_ image: CGImage, windowFrame: CGRect) async -> Readout? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                request.recognitionLanguages = ["it-IT", "en-US"]
                do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
                catch { continuation.resume(returning: nil); return }
                let controls = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }.prefix(200).compactMap { result -> Control? in
                    guard let text = result.topCandidates(1).first, text.confidence >= 0.5 else { return nil }
                    let box = result.boundingBox
                    let frame = CGRect(x: windowFrame.minX + box.minX * windowFrame.width,
                                       y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
                                       width: box.width * windowFrame.width, height: box.height * windowFrame.height)
                    return Control(text: text.string, frame: frame)
                }
                continuation.resume(returning: controls.isEmpty ? nil : Readout(controls: controls))
            }
        }
    }

    nonisolated static func recognize(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["it-IT", "en-US"]
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = (request.results ?? [])
                    .sorted { lhs, rhs in
                        // Vision's origin is bottom-left: higher y is higher on screen.
                        abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01
                            ? lhs.boundingBox.midY > rhs.boundingBox.midY
                            : lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }
}
