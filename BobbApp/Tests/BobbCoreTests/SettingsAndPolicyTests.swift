import Foundation
import Testing
@testable import BobbCore

@Suite("Settings, memory policy, model manifest, localization")
struct SettingsAndPolicyTests {
    @Test func settingsDecodeLenientlyFieldByField() throws {
        let json = #"{"floor": 2.5, "language": "it", "memoryRetentionDays": 90, "quietFrom": 99, "unknown": true}"#
        let settings = try JSONDecoder().decode(BobbSettings.self, from: Data(json.utf8))
        #expect(settings.floor == 0.60)
        #expect(settings.language == .it)
        #expect(settings.memoryRetentionDays == 90)
        #expect(settings.quietFrom == 20)
    }

    @Test func settingsMapToTheDaemonFrame() {
        var settings = BobbSettings()
        settings.toneCheck = false
        settings.quietHoursEnabled = true
        settings.quietFrom = 21
        settings.quietTo = 7
        let frame = settings.daemonFrame()
        #expect(frame.proactiveKinds == ["mail.opened", "message.opened", "calendar.upcoming"])
        #expect(frame.quietHours == [21, 7])
        settings.quietTo = 21
        #expect(settings.daemonFrame().quietHours == nil)
    }

    @Test func settingsRoundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bobb-settings-\(UUID()).json")
        let store = SettingsStore(url: url)
        var settings = BobbSettings()
        settings.language = .en
        settings.extraProtectedApps = ["com.bank.app"]
        try store.save(settings)
        #expect(store.load() == settings)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func hotkeyDisplay() {
        #expect(Hotkey.default.display == "⌥Space")
        #expect(Hotkey(keyCode: 40, modifiers: Hotkey.command | Hotkey.shift).display == "⇧⌘K")
    }

    @Test func protectedAndPrivateWindowsAreNeverRead() {
        var policy = ScreenMemoryPolicy(extraProtected: ["com.bank.app"])
        #expect(!policy.mayRead(bundleId: "com.1password.1password", appName: "1Password", windowTitle: "Vault"))
        #expect(!policy.mayRead(bundleId: "com.bank.app", appName: "Bank", windowTitle: "Home"))
        #expect(!policy.mayRead(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Navigazione privata"))
        #expect(!policy.mayRead(bundleId: "com.bobb.app", appName: "Bobb", windowTitle: "Mind"))
        #expect(policy.mayRead(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Docs"))
        #expect(policy.frame(app: "1Password", bundleId: "com.1password.1password", window: "x", text: String(repeating: "secret ", count: 20)) == nil)
    }

    @Test func unchangedWindowsAreNotResentUntilStale() {
        var policy = ScreenMemoryPolicy(resendAfter: 60)
        let text = "Quarterly report\nRevenue grew 12% year over year, driven by enterprise renewals."
        let now = Date(timeIntervalSince1970: 1000)
        #expect(policy.frame(app: "Pages", bundleId: "com.apple.iWork.Pages", window: "Q3", text: text, now: now) != nil)
        #expect(policy.frame(app: "Pages", bundleId: "com.apple.iWork.Pages", window: "Q3", text: text, now: now.addingTimeInterval(10)) == nil)
        #expect(policy.frame(app: "Pages", bundleId: "com.apple.iWork.Pages", window: "Q3", text: text, now: now.addingTimeInterval(61)) != nil)
        #expect(policy.frame(app: "Pages", bundleId: "com.apple.iWork.Pages", window: "Q3", text: "too short", now: now) == nil)
    }

    @Test func normalizeCollapsesWhitespaceAndRepeats() {
        #expect(ScreenMemoryPolicy.normalize("a   b\n\n a   b \nc", limit: 100) == "a b\nc")
        #expect(ScreenMemoryPolicy.normalize("abcdef", limit: 3) == "abc")
    }

    @Test func manifestIsPinnedAndComplete() {
        let manifest = ModelManifest.default
        #expect(manifest.directoryName == "Llama-3.2-3B-Instruct-4bit")
        #expect(manifest.revision.count == 40)
        #expect(manifest.files.allSatisfy { $0.sha256.count == 64 })
        #expect(manifest.totalBytes > 1_800_000_000)
        #expect(manifest.url(for: manifest.files[0]).absoluteString.contains("/resolve/\(manifest.revision)/config.json"))
    }

    @Test func installationCheckFindsMissingAndTruncatedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bobb-models-\(UUID())")
        let manifest = ModelManifest(id: "x/tiny", revision: String(repeating: "0", count: 40), files: [
            ModelFile(name: "a.json", size: 3, sha256: String(repeating: "0", count: 64)),
            ModelFile(name: "b.bin", size: 5, sha256: String(repeating: "0", count: 64)),
        ], license: "", licenseURL: "")
        let modelDir = ModelInstallation.directory(for: manifest, in: dir)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: modelDir.appendingPathComponent("a.json"))
        try Data("ab".utf8).write(to: modelDir.appendingPathComponent("b.bin"))
        #expect(ModelInstallation.missingOrIncomplete(manifest, in: dir).map(\.name) == ["b.bin"])
        try Data("abcde".utf8).write(to: modelDir.appendingPathComponent("b.bin"))
        #expect(ModelInstallation.isInstalled(manifest, in: dir))
    }

    @Test func everyStringHasBothLanguages() {
        #expect(L10n.table.count == L10n.Key.allCases.count)
        for (key, pair) in L10n.table {
            #expect(!pair.0.isEmpty && !pair.1.isEmpty, "\(key) is missing a translation")
        }
    }

    @Test func placeholdersAreReplaced() {
        let saved = L10n.code
        defer { L10n.code = saved }
        L10n.code = "it"
        #expect(L10n.t(.licenseTrial, ["days": "3"]) == "Prova gratuita · 3 giorni rimasti")
        L10n.code = "en"
        #expect(L10n.t(.licenseTrial, ["days": "3"]) == "Free trial · 3 days left")
        #expect(L10n.relative(1000, now: 1030) == "just now")
        #expect(L10n.relative(1000, now: 1000 + 2 * 86400) == "2 days ago")
    }
}
