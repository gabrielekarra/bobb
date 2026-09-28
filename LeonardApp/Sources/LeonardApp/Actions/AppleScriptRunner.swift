import AppKit
import Foundation

/// Runs small AppleScripts in-process. Scripts are compiled once and cached,
/// because compiling costs more than running a one-line `tell`.
///
/// Only ever scripts Mail, only ever with the fixed sources in this target:
/// no text from an email or from the model is ever spliced into script
/// source. Values go in as handler arguments, which AppleScript treats as
/// data.
@MainActor
final class AppleScriptRunner {
    static let shared = AppleScriptRunner()

    private var compiled: [String: NSAppleScript] = [:]

    enum Failure: Error, CustomStringConvertible {
        case compile(String)
        case run(Int, String)

        var description: String {
            switch self {
            case .compile(let message): "compile: \(message)"
            case .run(let code, let message): "\(code): \(message)"
            }
        }

        /// -1743: the user has not allowed Leonard to control this app.
        var isPermissionDenied: Bool {
            if case .run(let code, _) = self { return code == -1743 || code == -1744 }
            return false
        }
    }

    /// Runs `source` as-is and returns its string result.
    func run(_ source: String) throws -> String {
        let script = try compile(source)
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw Self.failure(error) }
        return result.stringValue ?? ""
    }

    /// Calls handler `name` defined in `source` with string arguments.
    func call(_ source: String, handler name: String, arguments: [String]) throws -> String {
        let script = try compile(source)
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        // 'ascr'/'psbr' is "call a subroutine in this script", 'snam' its
        // name and '----' the direct object; spelled out so this file needs
        // only AppKit, not the Carbon OSA headers.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(0x6173_6372),
            eventID: AEEventID(0x7073_6272),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(-1),
            transactionID: AETransactionID(0)
        )
        event.setParam(NSAppleEventDescriptor(string: name.lowercased()), forKeyword: AEKeyword(0x736E_616D))
        event.setParam(list, forKeyword: AEKeyword(0x2D2D_2D2D))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw Self.failure(error) }
        return result.stringValue ?? ""
    }

    private func compile(_ source: String) throws -> NSAppleScript {
        if let script = compiled[source] { return script }
        guard let script = NSAppleScript(source: source) else { throw Failure.compile("could not create script") }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw Failure.compile((error?[NSAppleScript.errorMessage] as? String) ?? "unknown")
        }
        compiled[source] = script
        return script
    }

    private static func failure(_ error: NSDictionary) -> Failure {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"
        return .run(code, message)
    }
}
