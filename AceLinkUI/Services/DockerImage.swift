import Foundation
import os

class DockerImage: Service {
    private var prepared = false
    private var prepareError: String?

    override var maxWait: DispatchTimeInterval { DispatchTimeInterval.seconds(1200) }
    override var checkEverySeconds: Double { 2.0 }
    override var defaultError: String { "Cannot pull \(AppConstants.Docker.image)." }

    override func run() {
        guard EngineRuntime.usesVM, let helperURL = EngineRuntime.helperURL else {
            _ = Process.runCommand("docker", "pull", AppConstants.Docker.image)
            return
        }
        // Downloads the kernel and the image the first time; after that it only checks.
        let process = Process.runCommand(
            helperURL.path, "prepare", "--image", AppConstants.Docker.image
        )
        if process.terminationStatus == 0 {
            prepared = true
        } else {
            let detail = process.standardErrorContents.trimmingCharacters(in: .whitespacesAndNewlines)
            os_log("Cannot prepare the engine VM: %{public}@", detail)
            prepareError = "Cannot prepare the AceStream engine. \(detail)"
        }
    }

    override func check() {
        if let prepareError = prepareError {
            callbackInMainThread(AppError(prepareError))
            return
        }
        super.check()
    }

    override func hasRunSuccesfully() -> Bool {
        if EngineRuntime.usesVM { return prepared }
        let process = Process.runCommand(
            "docker", "image", "inspect", "-f", "OK", AppConstants.Docker.image
        )
        return process.terminationStatus == 0
    }
}
