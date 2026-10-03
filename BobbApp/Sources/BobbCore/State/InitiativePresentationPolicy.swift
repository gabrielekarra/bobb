import Foundation

/// Context initiatives may surface once, between interactions, without taking focus.
public enum InitiativePresentationPolicy {
    public static func mayPresent(settings: BobbSettings, busy: Bool, keysIdle: Double,
                                  inputIdle: Double, frontApp: String, hour: Int) -> Bool {
        guard settings.watching, settings.contextProactive, settings.memoryEnabled,
              !busy, keysIdle >= 5, inputIdle < 120,
              frontApp != "com.bobb.app",
              !ScreenMemoryPolicy(extraProtected: settings.extraProtectedApps + settings.bobb.boundaries.excludedApps)
                .isProtected(bundleId: frontApp, appName: frontApp) else { return false }
        let calls = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp"]
        guard !calls.contains(frontApp) else { return false }
        if let hours = settings.quietHours {
            let quiet = hours[0] < hours[1] ? (hour >= hours[0] && hour < hours[1]) : (hour >= hours[0] || hour < hours[1])
            if quiet { return false }
        }
        return true
    }
}
