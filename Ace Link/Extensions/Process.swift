import Foundation
import os

// Weak maps to store additional data for the extension.
private let standardOutputMap = NSMapTable<Process, NSString>.weakToStrongObjects()
private let standardErrorMap = NSMapTable<Process, NSString>.weakToStrongObjects()

extension Process {
    var standardOutContents: String {
        get { (standardOutputMap.object(forKey: self) as String?) ?? "" }
        set { standardOutputMap.setObject(NSString(string: newValue), forKey: self) }
    }

    var standardErrorContents: String {
        get { (standardErrorMap.object(forKey: self) as String?) ?? "" }
        set { standardErrorMap.setObject(NSString(string: newValue), forKey: self) }
    }

    var userDockerSocket: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userSocketPath = home.path + "/.docker/run/docker.sock"
        if FileManager.default.fileExists(atPath: userSocketPath) {
            return userSocketPath
        }
        return nil
    }

    /// True if the user picked a Docker context (Colima, OrbStack, a remote host…).
    static var hasSelectedDockerContext: Bool {
        let environment = ProcessInfo.processInfo.environment
        if let context = environment["DOCKER_CONTEXT"], !context.isEmpty {
            return true
        }
        let configDir = environment["DOCKER_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker")
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = config["currentContext"] as? String
        else { return false }
        return !context.isEmpty && context != "default"
    }

    static func runCommand(_ arguments: String...) -> Self {
        runCommand(arguments)
    }

    static func runCommand(_ arguments: [String]) -> Self {
        let process = Self()

        process.launchPath = "/usr/bin/env"
        process.arguments = arguments
        // Keep the user's environment (DOCKER_HOST, DOCKER_CONTEXT…) so Docker works
        // the same as in Terminal.
        var environment = ProcessInfo.processInfo.environment
        // Apps opened from Finder get a minimal PATH; add where Docker usually lives
        // (Homebrew on Apple Silicon, Homebrew on Intel, MacPorts).
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            + ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        // Don't attempt to download/run arm64 packages because they're not supported.
        environment["DOCKER_DEFAULT_PLATFORM"] = "linux/amd64"
        process.environment = environment

        // Docker-for-Mac allows both /Users/<user>/.docker/run/docker.sock (new)
        // and /var/run/docker.sock (legacy but supported). Only force it when the
        // user hasn't chosen another Docker host or context (blaise-io/acelink#77).
        if environment["DOCKER_HOST"] == nil, !hasSelectedDockerContext,
           let userDockerSocket = process.userDockerSocket {
            process.environment?["DOCKER_HOST"] = "unix://" + userDockerSocket
        }

        os_log("Running command: %{public}@", arguments.joined(separator: " ").scrubHashes())

        let outputPipe = Pipe(), errorPipe = Pipe()

        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.launch()
        process.waitUntilExit()

        process.standardOutContents = outputPipe.readFile()
        process.standardErrorContents = errorPipe.readFile()

        os_log("StandardOut: %{public}@", process.standardOutContents.scrubHashes())
        os_log("standardError: %{public}@", process.standardErrorContents.scrubHashes())

        return process
    }
}
