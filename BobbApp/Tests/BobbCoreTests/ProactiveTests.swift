import Foundation
import Testing
@testable import BobbCore

@Test func pausingObservationDisablesContextAndPromiseInferenceOnTheWire() throws {
    var settings = BobbSettings()
    settings.watching = false
    let frame = settings.daemonFrame()
    #expect(frame.contextProactive == false)
    #expect(frame.trackPromises == false)
    let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as! [String: Any]
    #expect(raw["context_proactive"] as? Bool == false)
    #expect(raw["track_promises"] as? Bool == false)
    settings.watching = true
    settings.contextProactive = false
    #expect(settings.daemonFrame().contextProactive == false)
    #expect(settings.daemonFrame().trackPromises == true)
}

@Test func olderSettingsAndWorkspaceSnapshotsRemainReadable() throws {
    let settings = try JSONDecoder().decode(BobbSettings.self, from: Data("{}".utf8))
    #expect(settings.contextProactive)
    let workspace = try JSONDecoder().decode(WorkspaceStateFrame.self,
        from: Data(#"{"agents":[],"jobs":[],"projects":[],"runs":[],"routines":[]}"#.utf8))
    #expect(workspace.initiatives == nil)
}

@Test func initiativesWaitForAUsefulMomentAndRespectQuietHours() {
    var settings = BobbSettings()
    func allowed(_ busy: Bool = false, _ keys: Double = 8, _ idle: Double = 10, _ app: String = "com.apple.Notes", _ hour: Int = 10) -> Bool {
        InitiativePresentationPolicy.mayPresent(settings: settings, busy: busy, keysIdle: keys,
            inputIdle: idle, frontApp: app, hour: hour)
    }
    #expect(allowed())
    #expect(!allowed(true))
    #expect(!allowed(false, 1))
    #expect(!allowed(false, 8, 180))
    #expect(!allowed(false, 8, 10, "us.zoom.xos"))
    #expect(!allowed(false, 8, 10, "com.bobb.app"))
    settings.quietHoursEnabled = true
    #expect(!allowed(false, 8, 10, "com.apple.Notes", 22))
    #expect(!allowed(false, 8, 10, "com.apple.Notes", 7))
    #expect(allowed())
    settings.watching = false
    #expect(!allowed())
    settings.watching = true
    settings.bobb.boundaries.excludedApps = ["com.apple.Notes"]
    #expect(!allowed())
}
