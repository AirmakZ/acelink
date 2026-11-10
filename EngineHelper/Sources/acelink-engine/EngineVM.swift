import Containerization
import ContainerizationArchive
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation

/// Runs the AceStream engine image (linux/amd64) in a Linux VM, through Rosetta.
/// Everything it downloads lives in ~/Library/Application Support/Ace Link/Engine.
final class EngineVM: @unchecked Sendable {
    // The kernel comes from Kata Containers, like Apple's own examples use; the init
    // filesystem must match the Containerization version in Package.swift.
    private static let kernelURL = URL(string:
        "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst"
    )!
    private static let kernelPathInArchive = "opt/kata/share/kata-containers/vmlinux.container"
    private static let initfsReference = "ghcr.io/apple/containerization/vminit:0.54.0"
    private static let amd64 = Platform(arch: "amd64", os: "linux")
    private static let containerID = "acelink-engine"

    private let imageReference: String
    private let root: URL
    private var container: LinuxContainer?
    private var forwarders: [PortForwarder] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var parentSource: DispatchSourceProcess?

    init(imageReference: String) {
        // "blaiseio/acelink:2.1.0" → "docker.io/blaiseio/acelink:2.1.0"
        let parts = imageReference.split(separator: "/")
        let hasRegistry = parts.count > 1
            && (parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost")
        self.imageReference = hasRegistry ? imageReference : "docker.io/" + imageReference
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ace Link/Engine")
    }

    private var kernelPath: URL { root.appendingPathComponent("kernel/vmlinux") }
    private var storePath: URL { root.appendingPathComponent("store") }
    private var initfsPath: URL { root.appendingPathComponent("initfs/vminit-0.54.0.ext4") }
    private var rootfsDirectory: URL { root.appendingPathComponent("rootfs") }
    private var runDirectory: URL { root.appendingPathComponent("run") }

    // MARK: - Prepare

    func prepare() async throws {
        try await ensureKernel()
        let store = try ImageStore(path: storePath)
        try await ensureInitfs(store)
        let image = try await ensureImage(store)
        _ = try await ensureRootfs(image)
        print("ready")
    }

    private func ensureKernel() async throws {
        guard !FileManager.default.fileExists(atPath: kernelPath.path) else { return }
        print("Downloading the Linux kernel…")
        let directory = kernelPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // curl, because URLSession was far slower here; -C - resumes an interrupted download.
        let download = directory.appendingPathComponent("kata.tar.zst")
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--fail", "--location", "--silent", "--show-error", "-C", "-",
                          "--output", download.path, Self.kernelURL.absoluteString]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else {
            throw EngineError("Cannot download the Linux kernel (curl exit \(curl.terminationStatus)).")
        }
        defer { try? FileManager.default.removeItem(at: download) }

        // vmlinux.container is a symlink to the versioned kernel next to it.
        var path = Self.kernelPathInArchive
        var (entry, data) = try ArchiveReader(file: download).extractFile(path: path)
        if entry.fileType == .symbolicLink, let target = entry.symlinkTarget {
            path = URL(fileURLWithPath: "/" + path).deletingLastPathComponent()
                .appendingPathComponent(target).standardized.path.dropFirst().description
            (_, data) = try ArchiveReader(file: download).extractFile(path: path)
        }
        try data.write(to: kernelPath, options: .atomic)
    }

    private func ensureInitfs(_ store: ImageStore) async throws {
        guard !FileManager.default.fileExists(atPath: initfsPath.path) else { return }
        print("Downloading the VM's init system…")
        try FileManager.default.createDirectory(
            at: initfsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let initImage = try await store.getInitImage(reference: Self.initfsReference)
        _ = try await initImage.initBlock(at: initfsPath, for: .linuxArm)
    }

    private func ensureImage(_ store: ImageStore) async throws -> Containerization.Image {
        if let image = try await store.getOrNil(reference: imageReference) {
            return image
        }
        print("Downloading \(imageReference)…")
        // A registry on this Mac (for testing images) has no TLS.
        let local = imageReference.hasPrefix("localhost") || imageReference.hasPrefix("127.0.0.1")
        return try await store.pull(reference: imageReference, platform: Self.amd64, insecure: local)
    }

    /// The image's root filesystem, unpacked once per image version. Each run uses a
    /// clone of it and starts from a clean filesystem.
    private func ensureRootfs(_ image: Containerization.Image) async throws -> URL {
        let name = image.digest.replacingOccurrences(of: "sha256:", with: "") + ".ext4"
        let path = rootfsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path.path) { return path }

        print("Unpacking the engine image…")
        try? FileManager.default.removeItem(at: rootfsDirectory) // Older image versions.
        try FileManager.default.createDirectory(at: rootfsDirectory, withIntermediateDirectories: true)
        let partial = rootfsDirectory.appendingPathComponent(name + ".partial")
        _ = try await EXT4Unpacker(capacityInBytes: 4.gib()).unpack(image, for: Self.amd64, at: partial)
        try FileManager.default.moveItem(at: partial, to: path)
        return path
    }

    // MARK: - Run

    func run(share: URL, ports: [UInt16], engineArguments: [String]) async throws {
        stopOnSignalsAndParentExit()

        let store = try ImageStore(path: storePath)
        guard FileManager.default.fileExists(atPath: kernelPath.path),
              FileManager.default.fileExists(atPath: initfsPath.path),
              let image = try await store.getOrNil(reference: imageReference)
        else { throw EngineError("The engine isn't prepared. Run prepare first.") }
        let pristineRootfs = try await ensureRootfs(image)

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let rootfs = runDirectory.appendingPathComponent("rootfs.ext4")
        try? FileManager.default.removeItem(at: rootfs)
        // An APFS clone shares the blocks until the engine writes; copyItem made a full copy.
        if clonefile(pristineRootfs.path, rootfs.path, 0) != 0 {
            try FileManager.default.copyItem(at: pristineRootfs, to: rootfs)
        }

        let log = runDirectory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logWriter = try FileWriter(url: log)

        var network = try VmnetNetwork()
        guard let interface = try network.createInterface(Self.containerID),
              let gateway = interface.ipv4Gateway
        else { throw EngineError("Cannot create the VM's network.") }
        let address = interface.ipv4Address.address.description

        guard let imageConfig = try await image.config(for: Self.amd64).config else {
            throw EngineError("The engine image has no configuration.")
        }
        let vmm = VZVirtualMachineManager(
            kernel: Kernel(path: kernelPath, platform: .linuxArm),
            initialFilesystem: .block(
                format: "ext4", source: initfsPath.path, destination: "/", options: ["ro"]
            ),
            rosetta: true
        )
        let container = try LinuxContainer(
            Self.containerID,
            rootfs: .block(format: "ext4", source: rootfs.path, destination: "/", options: []),
            vmm: vmm
        ) { config in
            config.cpus = 4
            config.memoryInBytes = 2.gib()
            config.hostname = "acelink"
            // Like Docker: the engine looks up its own hostname to find its local IPs.
            var hosts = Hosts.default
            hosts.entries.append(.init(ipAddress: address, hostnames: ["acelink"]))
            config.hosts = hosts
            config.interfaces = [interface]
            config.dns = DNS(nameservers: [gateway.description])
            config.mounts += [
                // The engine reads its hardware id from here and fails without it, which
                // shows up as "Cannot get stream title" (blaise-io/acelink#100).
                .any(type: "tmpfs", source: "tmpfs", destination: "/dev/disk/by-id",
                     options: ["rw", "noexec", "size=4k"]),
                // Ace Link writes the players' playlists here; the container serves them.
                .share(source: share.path, destination: "/acelink"),
            ]
            config.bootLog = .file(path: runDirectory.appendingPathComponent("boot.log"), append: false)

            // QuickTime and Safari can't play a local m3u8 file, so the playlists are
            // served over HTTP, next to the engine (see PlaylistServer in the app).
            let playlistServer = "cd /acelink && python3 -m http.server 6888 >/dev/null 2>&1 &"
            var process = LinuxProcessConfiguration(from: imageConfig)
            process.arguments = ["/bin/sh", "-c", playlistServer + " exec \"$@\"", "sh"]
                + process.arguments + engineArguments
            process.stdout = logWriter
            process.stderr = logWriter
            config.process = process
        }
        self.container = container

        print("Booting the engine VM…")
        try await container.create()
        try await container.start()
        forwarders = try ports.map { try PortForwarder(port: $0, to: address) }
        print("running \(address)")

        let status = try await container.wait()
        print("Engine exited: \(status)")
        try? await container.stop()
        try? network.releaseInterface(Self.containerID)
        exit(status.exitCode == 0 ? 0 : 1)
    }

    /// Ace Link stops the engine with SIGTERM. If Ace Link crashes or is killed,
    /// the engine goes away with it instead of keeping the ports taken.
    private func stopOnSignalsAndParentExit() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig)
            source.setEventHandler { [weak self] in self?.stopAndExit() }
            source.resume()
            signalSources.append(source)
        }
        let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit)
        parent.setEventHandler { [weak self] in self?.stopAndExit() }
        parent.resume()
        parentSource = parent
    }

    private func stopAndExit() {
        Task {
            if let container = container {
                try? await container.stop()
            }
            exit(0)
        }
    }
}

struct EngineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Writes the engine's output to a log file.
final class FileWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func write(_ data: Data) throws { handle.write(data) }
    func close() throws { try handle.close() }
}
