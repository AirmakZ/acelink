import Foundation

// QuickTime and Safari cannot play streams when loaded from a m3u8 file from the local filesystem.
class PlaylistServer: Service {
    private let engine: AceStreamEngine
    private let stream: StreamFile
    override var defaultError: String { "Cannot launch Python server." }

    init(engine: AceStreamEngine, stream: StreamFile) {
        self.engine = engine
        self.stream = stream
        super.init()
    }

    override func run() {
        // The playlist goes in through an environment variable, so quotes in the title
        // can't break the shell command. The web server is started once per engine;
        // when it already runs, the second one exits and the file is still served.
        let cmdInContainer = "printf '%s\\n' \"$ACELINK_M3U\" > \(stream.playlistFileName);" +
            "python3 -m http.server \(AppConstants.Docker.proxyPort)"
        _ = Process.runCommand(
            "docker", "exec", "--detach", "--workdir=/acelink",
            "--env=ACELINK_M3U=\(stream.m3uData)", AppConstants.Docker.containerName,
            "sh", "-c", cmdInContainer
        )
    }

    override func check() {
        urlSession.dataTask(with: stream.playlistURL) { _, response, _ in
            if let response = response as? HTTPURLResponse {
                if response.statusCode == 200 {
                    self.callbackInMainThread()
                    return
                }
            }
            self.scheduleCheck()
        }.resume()
    }
}
