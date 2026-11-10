import Foundation
import os

/// Where the AceStream engine runs. On Apple silicon with macOS 26 it runs in a Linux VM
/// started by the `acelinkui-engine` helper inside the app (Apple's Containerization
/// framework), so Docker isn't needed. Elsewhere, or with the `UseDocker` default set,
/// it runs in Docker as before.
enum EngineRuntime {
    /// The helper, next to the app's executable. Missing when it couldn't be built.
    static let helperURL = Bundle.main.url(forAuxiliaryExecutable: "acelinkui-engine")

    static let usesVM: Bool = {
        guard #available(macOS 26, *), helperURL != nil,
              !UserDefaults.standard.bool(forKey: "UseDocker") else { return false }
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }()

    /// The helper's data: kernel, images, logs (same folder the helper uses).
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AceLinkUI/Engine")

    /// Shared with the VM as /acelink: the players' playlists go here.
    static let playlistDirectory = directory.appendingPathComponent("playlists")

    static var isAvailable: Bool {
        usesVM || Process.runCommand("docker", "--version").terminationStatus == 0
    }

    static var startingMessage: String {
        usesVM ? "Starting AceStream engine…" : "Starting Docker…"
    }

    static var preparingMessage: String {
        usesVM
            ? "Preparing the AceStream engine (the first run downloads about 600 MB)…"
            : "Preparing AceStream image (first run can take a while)…"
    }

    // MARK: - VM

    private static let lock = NSLock()
    private static var vmProcess: Process?

    /// Starts the engine VM. The helper keeps running until it is stopped.
    static func startVM(engineArguments: [String]) -> String? {
        guard let helperURL = helperURL else { return "The engine helper is missing." }
        stopVM()

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "run", "--image", AppConstants.Docker.image,
            "--share", playlistDirectory.path,
            "--port", String(AppConstants.Docker.enginePort),
            "--port", String(AppConstants.Docker.proxyPort),
            "--",
        ] + engineArguments
        let log = directory.appendingPathComponent("helper.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { process in
            os_log("Engine VM helper exited with status %d.", process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            return "Cannot start the engine helper: \(error.localizedDescription)"
        }
        os_log("Started engine VM helper (pid %d).", process.processIdentifier)
        lock.withLock { vmProcess = process }
        return nil
    }

    /// True while the helper started by `startVM` is running.
    static var vmIsRunning: Bool {
        lock.withLock { vmProcess?.isRunning ?? false }
    }

    /// Stops the engine VM and waits (briefly) until the helper has exited, so the ports
    /// are free for the next one.
    static func stopVM() {
        guard let process = lock.withLock({ () -> Process? in
            defer { vmProcess = nil }
            return vmProcess
        }), process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
