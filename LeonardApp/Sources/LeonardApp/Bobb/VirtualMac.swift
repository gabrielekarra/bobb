import AppKit
import Observation
import UniformTypeIdentifiers
@preconcurrency import Virtualization

/// Optional Apple-silicon Mac computer. No shared folders or networking by
/// default. Installation uses an IPSW selected by the user, never a hidden
/// download or a modification to the host's system disk.
@MainActor
@Observable
final class VirtualMac {
    var status = "Not configured"
    var progress: Double = 0
    var networkEnabled = false
    private var machine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var window: NSWindow?
    private var progressTimer: Timer?
    private let directory = AppPaths.dataDirectory.appendingPathComponent("VirtualMac", isDirectory: true)
    var installed: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("installed").path) }
    var running: Bool { machine?.state == .running }

    func installFromPicker() {
        guard machine == nil else { return }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.init(filenameExtension: "ipsw") ?? .data]
        picker.canChooseDirectories = false; picker.canChooseFiles = true
        guard picker.runModal() == .OK, let ipsw = picker.url else { return }
        Task {
            do { try await install(ipsw) } catch { status = error.localizedDescription }
        }
    }

    private func install(_ ipsw: URL) async throws {
        #if arch(arm64)
        guard VZVirtualMachine.isSupported, ProcessInfo.processInfo.physicalMemory >= 24 * 1_073_741_824 else {
            throw NSError(domain: "BobbVM", code: 1, userInfo: [NSLocalizedDescriptionKey: "The virtual Mac requires Apple silicon and at least 24 GB of RAM alongside Bobb."])
        }
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "BobbVM", code: 2, userInfo: [NSLocalizedDescriptionKey: "A virtual Mac directory already exists. Review it before replacing an interrupted installation."])
        }
        status = "Reading the macOS restore image…"
        let restore = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let supported = restore.mostFeaturefulSupportedConfiguration, supported.hardwareModel.isSupported else {
            throw NSError(domain: "BobbVM", code: 3, userInfo: [NSLocalizedDescriptionKey: "This macOS image is not supported on this Mac."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try supported.hardwareModel.dataRepresentation.write(to: directory.appendingPathComponent("hardware.bin"), options: .atomic)
        let identifier = VZMacMachineIdentifier()
        try identifier.dataRepresentation.write(to: directory.appendingPathComponent("machine.bin"), options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: directory.appendingPathComponent("auxiliary.bin"), hardwareModel: supported.hardwareModel, options: [])
        let disk = directory.appendingPathComponent("disk.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 64 * 1_073_741_824); try handle.close()
        let cpu = max(supported.minimumSupportedCPUCount, min(4, ProcessInfo.processInfo.activeProcessorCount))
        let ram = max(supported.minimumSupportedMemorySize, 8 * 1_073_741_824)
        try JSONEncoder().encode(Resources(cpu: cpu, memory: ram)).write(to: directory.appendingPathComponent("resources.json"), options: .atomic)
        let vm = try makeMachine(); machine = vm; inspect()
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw); self.installer = installer
        status = "Installing macOS…"
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.progress = self?.installer?.progress.fractionCompleted ?? 0 }
        }
        defer { progressTimer?.invalidate(); progressTimer = nil; self.installer = nil }
        try await installer.install()
        try Data().write(to: directory.appendingPathComponent("installed"), options: .atomic)
        progress = 1; status = "macOS installed. Complete setup in the virtual Mac."
        #else
        throw NSError(domain: "BobbVM", code: 4, userInfo: [NSLocalizedDescriptionKey: "macOS guests require Apple silicon."])
        #endif
    }

    private struct Resources: Codable { var cpu: Int; var memory: UInt64 }

    private func makeMachine() throws -> VZVirtualMachine {
        #if arch(arm64)
        guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("hardware.bin"))),
              let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("machine.bin"))) else {
            throw NSError(domain: "BobbVM", code: 5, userInfo: [NSLocalizedDescriptionKey: "The virtual Mac configuration is damaged."])
        }
        let resources = try JSONDecoder().decode(Resources.self, from: Data(contentsOf: directory.appendingPathComponent("resources.json")))
        let config = VZVirtualMachineConfiguration()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware; platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: directory.appendingPathComponent("auxiliary.bin"))
        config.platform = platform; config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = resources.cpu; config.memorySize = resources.memory
        let disk = try VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("disk.img"), readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        if networkEnabled {
            let network = VZVirtioNetworkDeviceConfiguration(); network.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [network]
        }
        try config.validate()
        return VZVirtualMachine(configuration: config)
        #else
        throw NSError(domain: "BobbVM", code: 4, userInfo: [NSLocalizedDescriptionKey: "macOS guests require Apple silicon."])
        #endif
    }
    func start() {
        guard installed, !running, installer == nil else { return }
        Task {
            do {
                let vm = try makeMachine(); machine = vm
                try await vm.start(); status = "Running"; inspect()
            } catch { status = error.localizedDescription }
        }
    }
    func stop() {
        guard installer == nil, let machine, machine.canRequestStop else { return }
        do { try machine.requestStop(); status = "Shutting down…" } catch { status = error.localizedDescription }
    }
    func inspect() {
        guard let machine else { return }
        let view = VZVirtualMachineView(); view.virtualMachine = machine; view.capturesSystemKeys = true
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Bobb — Virtual Mac"; w.isReleasedWhenClosed = false; window = w
        }
        window?.contentView = view; window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
