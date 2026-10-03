import Foundation
import Testing
@testable import BobbCore

@Suite struct UserApplicationTests {
    let chrome = UserApplication(bundleId: "com.google.Chrome", name: "Google Chrome", aliases: ["Chrome"])
    let safari = UserApplication(bundleId: "com.apple.Safari", name: "Safari")

    @Test func reusesTheActiveBrowserBeforeTheDefault() {
        #expect(UserApplicationSelection.browser(goal: "Cerca una ricetta", active: chrome.bundleId,
            defaultBrowser: safari.bundleId, candidates: [safari, chrome]) == chrome)
        #expect(UserApplicationSelection.browser(goal: "Cerca una ricetta", active: "com.apple.Notes",
            defaultBrowser: safari.bundleId, candidates: [chrome, safari]) == safari)
    }
    @Test func explicitBrowserNamesRespectWordBoundaries() {
        #expect(UserApplicationSelection.browser(goal: "Apri Chrome e cerca la ricetta", active: safari.bundleId,
            defaultBrowser: safari.bundleId, candidates: [safari, chrome]) == chrome)
        #expect(UserApplicationSelection.browser(goal: "Search for chromium", active: safari.bundleId,
            defaultBrowser: safari.bundleId, candidates: [safari, chrome]) == safari)
        #expect(UserApplicationSelection.browser(goal: "Open Chrome or Safari", active: safari.bundleId,
            defaultBrowser: safari.bundleId, candidates: [safari, chrome]) == nil)
    }
    @Test func doesNotInventAnAppWhenTheUsersBrowserIsUnavailable() {
        #expect(UserApplicationSelection.browser(goal: "Cerca", active: nil, defaultBrowser: "missing",
            candidates: [chrome, safari]) == nil)
        #expect(UserApplicationSelection.browser(goal: "Cerca", active: nil, defaultBrowser: nil, candidates: []) == nil)
    }
    @Test func personalBrowserRespectsBothAppAndSiteBoundaries() {
        var bounds = BoundaryConfiguration()
        bounds.apps = [AppBoundary(id: "web:example.test", name: "example.test", actions: ["write": .deny])]
        let policy = ActionPolicy(boundaries: bounds)
        #expect(policy.evaluate(operation: .type, label: "Search", role: "AXTextField", appBundleId: chrome.bundleId,
            appName: chrome.name, typedText: "recipe", websiteURL: "https://example.test/") == .deny(reason: "boundary:write"))
        bounds.apps = [AppBoundary(id: chrome.bundleId, name: chrome.name, actions: ["write": .deny]),
                      AppBoundary(id: "web:example.test", name: "example.test", actions: ["write": .allow])]
        #expect(ActionPolicy(boundaries: bounds).evaluate(operation: .type, label: "Search", role: "AXTextField",
            appBundleId: chrome.bundleId, appName: chrome.name, typedText: "recipe", websiteURL: "https://example.test/") == .deny(reason: "boundary:write"))
    }
    @Test func excludedSitesAndInvalidURLsCannotBeOperatedInARealBrowser() {
        var bounds = BoundaryConfiguration(); bounds.excludedApps = ["web:excluded.test"]
        let policy = ActionPolicy(boundaries: bounds)
        for url in ["https://excluded.test/", "https://name:secret@example.test/", "file:///tmp/document"] {
            #expect(policy.evaluate(operation: .click, label: "Continue", role: "AXButton", appBundleId: chrome.bundleId,
                appName: chrome.name, websiteURL: url) == .deny(reason: "unavailableWebsite"))
        }
        #expect(policy.evaluate(operation: .click, label: "Continue", role: "AXButton", appBundleId: chrome.bundleId,
            appName: chrome.name, websiteURL: "https://allowed.test/") == .allow)
    }
    @Test func returnInAPersonalBrowserStillChecksTheSiteSendBoundary() {
        var bounds = BoundaryConfiguration()
        bounds.apps = [AppBoundary(id: "web:example.test", name: "example.test", actions: ["send": .deny])]
        #expect(ActionPolicy(boundaries: bounds).evaluate(operation: .key, label: "Return", role: "key",
            appBundleId: chrome.bundleId, appName: chrome.name, key: .returnKey,
            websiteURL: "https://example.test/") == .deny(reason: "boundary:send"))
    }
}
