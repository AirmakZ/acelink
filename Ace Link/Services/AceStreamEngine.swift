import Foundation
import os

class AceStreamEngine: Service {
    var accessToken: String?
    var playlist: String?
    var containerID: String?
    let token = UUID().uuidString
    private var runError: String?

    override var defaultError: String { "Cannot run AceStream server." }

    override init() {
        // `rm -f` waits until the old container is gone; `kill` doesn't, and the name
        // would still be taken when the new container starts.
        _ = Process.runCommand("docker", "rm", "--force", AppConstants.Docker.containerName)
        super.init()
    }

    override func run() {
        let process = Process.runCommand(
            "docker",
            "run",
            "--rm",
            "--detach",
            "--publish=\(AppConstants.Docker.enginePort):\(AppConstants.Docker.enginePort)",
            "--publish=\(AppConstants.Docker.proxyPort):\(AppConstants.Docker.proxyPort)",
            "--name=\(AppConstants.Docker.containerName)",
            // The engine reads its hardware id from here and fails without it, which
            // shows up as "Cannot get stream title" (blaise-io/acelink#100).
            "--tmpfs=/dev/disk/by-id:rw,noexec,size=4k",
            AppConstants.Docker.image,
            "--client-console",
            "--access-token=\(token)",
            "--allow-user-config",
            "--bind-all",
            "--live-buffer-time=15",
            "--live-cache-type=memory",
            "--vod-buffer=15",
            "--vod-cache-type=memory"
        )
        if process.terminationStatus != 0 || process.standardOutContents.isEmpty {
            os_log("Cannot start engine container: %{public}@", process.standardErrorContents)
            runError = "Cannot start the AceStream engine container."
            return
        }
        containerID = process.standardOutContents
    }

    override func check() {
        if let runError = runError {
            callbackInMainThread(AppError(runError))
            return
        }
        let serverURL = AppConstants.Docker.baseURL
            .appendingPathComponent("/webui/app/\(token)/server")
        os_log("Check server up at %{public}@ …", serverURL.absoluteString)
        urlSession.dataTask(with: serverURL) { data, _, _ in
            if let data = data, let str = String(data: data, encoding: .utf8) {
                self.accessToken = str.matches(for: "\"access_token\": \"([^\"]{64})\"").first
                self.playlist = str.matches(for: "\"playlist_id\": \"([^\"]{7})\"").first
                if self.containerID != nil, self.accessToken != nil {
                    self.callbackInMainThread()
                    return
                }
            }
            self.scheduleCheck()
        }.resume()
    }
}
