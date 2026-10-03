import AppKit
import BobbCore

/// Explicit read-only diagnostic. Only booleans, counts and error codes
/// leave the process; real email text and headers stay in memory.
@MainActor
func runMailDiagnostics() {
    Task {
        let settings = SettingsStore(url: AppPaths.settingsFile).load()
        let sensor = MailSensor()
        sensor.permitted = {
            settings.watching && settings.bobb.boundaries.app(bundleId: MailSensor.bundleId, name: "Mail") != nil
                && !ScreenMemoryPolicy(extraProtected: settings.extraProtectedApps).isProtected(bundleId: MailSensor.bundleId, appName: "Mail")
        }
        let report = sensor.liveDiagnostics()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            if let path = AppPaths.argument("--report") { try? data.write(to: URL(fileURLWithPath: path)) }
            print(String(decoding: data, as: UTF8.self))
        }
        exit(0)
    }
}
