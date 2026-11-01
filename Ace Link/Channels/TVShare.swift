import Foundation
import Network
import os

/// "Share to TV": serves an M3U playlist of all channels on the local network so a TV
/// app (e.g. m3u-ip.tv) can play them. The streams themselves come straight from the
/// AceStream engine on port 6878, which AppDelegate keeps running while this is on.
final class TVShare: ObservableObject {
    static let shared = TVShare()

    static let port: UInt16 = 8765
    static let playlistPath = "/acelink.m3u"
    private static let enabledKey = "tvSharingEnabled"

    enum State: Equatable {
        case off
        case starting(String)
        case on
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)

    private var listener: NWListener?
    private var sleepActivity: NSObjectProtocol?
    private let queue = DispatchQueue(label: "acelink.tvshare")

    var playlistURL: String {
        "http://\(Self.localIPAddress() ?? "<your-mac-ip>"):\(Self.port)\(Self.playlistPath)"
    }

    func set(_ state: State) {
        if Thread.isMainThread {
            self.state = state
        } else {
            DispatchQueue.main.async { self.state = state }
        }
    }

    // MARK: - On / off

    /// Starts the playlist server and keeps the Mac awake. Returns an error message on failure.
    func enable() -> String? {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)

        if sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Sharing streams to TV"
            )
        }
        if listener == nil {
            do {
                try startServer()
            } catch {
                return "Cannot open port \(Self.port): \(error.localizedDescription)"
            }
        }
        return nil
    }

    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        listener?.cancel()
        listener = nil
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        set(.off)
    }

    // MARK: - HTTP server

    private func startServer() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                os_log("TV playlist server failed: %{public}@", error.localizedDescription)
                self?.set(.failed("Port \(TVShare.port) is in use by another app."))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        os_log("TV playlist server listening on port %d", Self.port)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response = self.response(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : "/"

        // Use the address the TV used to reach us, so stream URLs work for it too.
        let hostHeader = lines.first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let host = hostHeader.flatMap { $0.split(separator: ":").first.map(String.init) }
            ?? Self.localIPAddress() ?? "127.0.0.1"

        if path == Self.playlistPath || path == "/" {
            let channels = DispatchQueue.main.sync { ChannelStore.shared.channels }
            let body = Self.playlist(channels: channels, host: host)
            return Self.http(200, type: "audio/x-mpegurl; charset=utf-8", body: Data(body.utf8))
        }

        if path.hasPrefix("/icons/") {
            let name = String(path.dropFirst("/icons/".count))
            if !name.contains("/"), !name.contains(".."),
               let data = try? Data(contentsOf: ChannelStore.iconsDir.appendingPathComponent(name)) {
                return Self.http(200, type: "image/png", body: data)
            }
        }
        return Self.http(404, type: "text/plain", body: Data("Not found".utf8))
    }

    static func playlist(channels: [Channel], host: String) -> String {
        var out = "#EXTM3U\n"
        for channel in channels {
            let group = clean(channel.name)
            var logo = ""
            if case let .image(fileName) = channel.icon {
                logo = " tvg-logo=\"http://\(host):\(port)/icons/\(fileName)\""
            }
            for link in channel.links {
                guard let stream = link.stream else { continue }
                let name = clean(link.name.isEmpty ? "Link" : link.name)
                let url = "http://\(host):\(AppConstants.Docker.enginePort)/ace/manifest.m3u8"
                    + "?\(stream.param)=\(stream.hash)&pid=acelink-tv"
                out += "#EXTINF:-1\(logo) group-title=\"\(group)\",\(group) · \(name)\n\(url)\n"
            }
        }
        return out
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func http(_ code: Int, type: String, body: Data) -> Data {
        let reason = code == 200 ? "OK" : "Not Found"
        let header = "HTTP/1.1 \(code) \(reason)\r\n" +
            "Content-Type: \(type)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    // MARK: - Network address

    /// The Mac's IPv4 address on the local network (Wi-Fi or Ethernet).
    static func localIPAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [(name: String, ip: String)] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(interface.ifa_flags) & IFF_UP) != 0,
                  (Int32(interface.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") { candidates.append((name, ip)) }
        }
        return candidates.sorted { $0.name < $1.name }.first?.ip
    }
}
