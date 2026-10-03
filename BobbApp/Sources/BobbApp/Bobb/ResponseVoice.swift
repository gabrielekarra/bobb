import AVFoundation
import BobbCore

@MainActor
final class ResponseVoice: NSObject, AVAudioPlayerDelegate {
    private var worker: Process?
    private var output: FileHandle?
    private var input: FileHandle?
    private var buffer = Data()
    private var queue: [Data] = []
    private var player: AVAudioPlayer?
    private var generation = UUID()
    private var completed = false
    private var permitted: (() -> Bool)?
    var onError: ((String) -> Void)?
    func speak(_ text: String, settings: BobbSettings, permitted: @escaping () -> Bool) {
        stop()
        guard permitted(), !text.isEmpty else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        if let hours = settings.quietHours {
            let quiet = hours[0] < hours[1] ? (hours[0]..<hours[1]).contains(hour) : hour >= hours[0] || hour < hours[1]
            if quiet { return }
        }
        self.permitted = permitted
        let token = generation
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let python: URL
        let directory: URL
        if let development = AppPaths.daemonDirectory {
            directory = URL(fileURLWithPath: development)
            python = directory.appendingPathComponent(".venv/bin/python3")
        } else {
            let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            directory = resources.appendingPathComponent("daemon")
            python = directory.appendingPathComponent("python/bin/python3")
        }
        process.executableURL = python; process.currentDirectoryURL = directory
        process.arguments = ["-s", "-m", "bobbd.tts", "--models-dir", AppPaths.modelsDirectory.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                               "LANG": "en_US.UTF-8", "PYTHONPATH": directory.path,
                               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }; self.receive(data)
            }
        }
        worker = process
        do {
            try process.run()
            let request = ["text": String(text.prefix(5000)), "locale": settings.language.code == "it" ? "it" : "en"]
            try input?.write(contentsOf: JSONEncoder().encode(request) + Data([10]))
        } catch { fail() }
    }
    private func receive(_ data: Data) {
        guard permitted?() == true else { stop(); return }
        guard !data.isEmpty else {
            output?.readabilityHandler = nil
            if !completed { fail() }
            return
        }
        buffer.append(data)
        guard buffer.count < 8_000_000 else { fail(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: line) else { fail(); return }
            if frame["error"] != nil { fail(); return }
            if let encoded = frame["audio"]?.stringValue, let audio = Data(base64Encoded: encoded) {
                queue.append(audio); playNext()
            }
            if frame["done"]?.boolValue == true { completed = true; try? input?.close(); input = nil }
        }
    }
    private func playNext() {
        guard permitted?() == true else { stop(); return }
        guard player == nil, !queue.isEmpty else { return }
        do {
            let next = try AVAudioPlayer(data: queue.removeFirst())
            next.delegate = self; player = next
            guard next.play() else { fail(); return }
        } catch { fail() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.player = nil
            if flag { self.playNext() } else { self.fail() }
        }
    }
    private func fail() {
        stop(); onError?(BobbCopy.t("The local voice is unavailable. Check the voice model download.", "La voce locale non è disponibile. Controlla il download del modello vocale."))
    }
    func stop() {
        permitted = nil
        generation = UUID(); player?.stop(); player = nil; queue.removeAll(); buffer.removeAll()
        completed = false
        output?.readabilityHandler = nil; try? output?.close(); output = nil
        try? input?.close(); input = nil
        if worker?.isRunning == true { worker?.terminate() }; worker = nil
    }
}
