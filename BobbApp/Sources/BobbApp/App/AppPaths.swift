import Foundation
import BobbCore

/// Where everything lives. One directory, owner-only, under Application
/// Support: settings, the audit trail, screen memory, the model, the
/// daemon's socket and lock. Logs go to ~/Library/Logs/Bobb, which is
/// where Console.app and a support request expect them.
enum AppPaths {
    static var dataDirectory: URL {
        if let override = argument("--data-dir") ?? ProcessInfo.processInfo.environment["BOBB_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bobb", isDirectory: true)
    }

    static var modelsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BOBB_MODELS_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "BobbDevelopmentModelsDirectory") as? String {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return dataDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Development bundles remember their checkout so Finder and login-item
    /// launches work without command-line arguments. Full bundles omit it.
    static var daemonDirectory: String? {
        argument("--daemon-dir") ?? ProcessInfo.processInfo.environment["BOBB_DAEMON_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "BobbDevelopmentDaemonDirectory") as? String
    }

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bobb", isDirectory: true)
    }

    static var socketPath: String {
        argument("--socket") ?? dataDirectory.appendingPathComponent("bobbd.sock").path
    }

    static var auditDatabase: String {
        argument("--audit-db") ?? dataDirectory.appendingPathComponent("audit.db").path
    }

    static var settingsFile: URL { dataDirectory.appendingPathComponent("app-settings.json") }
    static var cuaDriver: URL? {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("drivers/cua-driver")
        if let packaged, FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        guard let daemonDirectory else { return nil }
        let checkout = URL(fileURLWithPath: daemonDirectory).deletingLastPathComponent()
        let binary = checkout.appendingPathComponent(".runtime/cua-driver/pinned/cua-driver-rs-0.31.0-darwin-arm64/cua-driver")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }
    static var licenseFile: URL { dataDirectory.appendingPathComponent("license.key") }

    static func prepare() {
        let fm = FileManager.default
        for dir in [dataDirectory, modelsDirectory, logsDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
    }

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func flag(_ name: String) -> Bool {
        CommandLine.arguments.contains(name)
    }
}

/// Facts about this build, stamped into Info.plist by `scripts/package.sh`.
enum BuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The day this build was made, which is what a license's
    /// `updates_until` is compared with. Unstamped development builds count
    /// as today.
    static var buildDate: Date {
        if let text = Bundle.main.object(forInfoDictionaryKey: "BobbBuildDate") as? String,
           let date = LicenseDates.parse(text) {
            return date
        }
        return Date()
    }

    /// The Ed25519 public key licenses are verified against. Release builds
    /// get the production key from `package.sh`; everything else carries the
    /// development key, whose private half is in `tools/license/`.
    static var licensePublicKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "BobbLicensePublicKey") as? String) ?? developmentLicenseKey
    }

    static let developmentLicenseKey = "pKVQLNy-XRirFvGnkNLtDBOHwpeMoz81bSN3RwGKy08"

    static var isDevelopmentBuild: Bool { !Bundle.main.bundleURL.path.hasSuffix(".app") }

    static let website = URL(string: "https://github.com/gabrielekarra/bobb")!
    static let buyURL = website
    static let releasesURL = URL(string: "https://github.com/gabrielekarra/bobb/releases")!
    static let supportEmail = "support@bobb.app"
}
