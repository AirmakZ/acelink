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
    private static let hideDeadLinksKey = "tvHideDeadLinks"

    enum State: Equatable {
        case off
        case starting(String)
        case on
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    /// Leave out links that were red in the last availability check.
    @Published var hideDeadLinks = UserDefaults.standard.object(forKey: hideDeadLinksKey)
        as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideDeadLinks, forKey: Self.hideDeadLinksKey) }
    }

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
            self.respond(to: request) { response in
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func respond(to request: String, send: @escaping (Data) -> Void) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let path = target.components(separatedBy: "?")[0]
        let query = URLComponents(string: target)?.queryItems ?? []

        // Use the address the TV used to reach us, so stream URLs work for it too.
        let hostHeader = lines.first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let host = hostHeader.flatMap { $0.split(separator: ":").first.map(String.init) }
            ?? Self.localIPAddress() ?? "127.0.0.1"

        if path == Self.playlistPath || path == "/" {
            let (channels, hidden) = DispatchQueue.main.sync {
                (ChannelStore.shared.channels, hideDeadLinks ? Self.deadLinkIDs() : [])
            }
            let body = Self.playlist(channels: channels, host: host, hiding: hidden)
            return send(Self.http(200, type: "audio/x-mpegurl; charset=utf-8", body: Data(body.utf8)))
        }

        if path.hasPrefix("/play/") {
            let hop = query.first { $0.name == "hop" }?.value.flatMap(Int.init) ?? 0
            return play(path: path, hop: hop, host: host, send: send)
        }

        if path.hasPrefix("/icons/") {
            let name = String(path.dropFirst("/icons/".count))
            if !name.contains("/"), !name.contains(".."),
               let data = try? Data(contentsOf: ChannelStore.iconsDir.appendingPathComponent(name)) {
                return send(Self.http(200, type: "image/png", body: data))
            }
        }
        send(Self.http(404, type: "text/plain", body: Data("Not found".utf8)))
    }

    // MARK: - Starting streams for the TV

    // A cold stream can take 10–60 s before the engine answers, and TV players give up
    // long before that (PLAYER_ERROR_CONNECTION_FAILED). So the TV asks us instead: we
    // start the stream in the engine and, until it is ready, answer every few seconds
    // with a redirect back to ourselves. Players follow redirects without timing out.
    // Once ready, we redirect to the engine's own HLS playlist.

    /// How long to hold each request before answering "ask again".
    private static let holdSeconds: TimeInterval = 6
    /// Redirects before giving up (≈ 50 s), so a dead link fails in reasonable time.
    private static let maxHops = 8

    private final class WarmUp {
        let created = Date()
        var readyPath: String?
        var failed = false
    }

    /// Stream hash -> warm-up. Only touched on `queue`.
    private var warmUps: [String: WarmUp] = [:]

    private func play(path: String, hop: Int, host: String, send: @escaping (Data) -> Void) {
        // Path: /play/<id|infohash>/<hash>.m3u8
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, ["id", "infohash"].contains(parts[1]),
              parts[2].hasSuffix(".m3u8") else {
            return send(Self.http(404, type: "text/plain", body: Data("Not found".utf8)))
        }
        let param = parts[1]
        let hash = String(parts[2].dropLast(".m3u8".count))
        guard hash.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            return send(Self.http(404, type: "text/plain", body: Data("Not found".utf8)))
        }

        let warmUp = warmUp(param: param, hash: hash, fresh: hop == 0)
        let deadline = Date().addingTimeInterval(Self.holdSeconds)
        os_log("TV asks for %{public}@ (attempt %d)", String(hash.prefix(7)), hop + 1)

        func poll() {
            if let readyPath = warmUp.readyPath {
                send(Self.redirect(to: "http://\(host):\(AppConstants.Docker.enginePort)\(readyPath)"))
            } else if warmUp.failed {
                send(Self.http(502, type: "text/plain", body: Data("Stream unavailable".utf8)))
            } else if Date() < deadline {
                queue.asyncAfter(deadline: .now() + 0.25, execute: poll)
            } else if hop < Self.maxHops {
                send(Self.redirect(to: "http://\(host):\(Self.port)\(path)?hop=\(hop + 1)"))
            } else {
                send(Self.http(504, type: "text/plain", body: Data("Stream took too long".utf8)))
            }
        }
        poll()
    }

    /// Starts (or reuses) loading a stream in the engine for the TV.
    private func warmUp(param: String, hash: String, fresh: Bool) -> WarmUp {
        if let existing = warmUps[hash],
           !(fresh && (existing.failed || Date().timeIntervalSince(existing.created) > 30)) {
            return existing
        }
        let warmUp = WarmUp()
        warmUps[hash] = warmUp

        var components = URLComponents(
            url: AppConstants.Docker.baseURL.appendingPathComponent("/ace/manifest.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: param, value: hash),
            URLQueryItem(name: "pid", value: "acelink-tv")
        ]
        let request = URLRequest(
            url: components.url!,
            timeoutInterval: Self.holdSeconds * Double(Self.maxHops + 1)
        )
        // URLSession follows the engine's redirect to the session playlist and only
        // returns once the engine has video ready.
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            self.queue.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   body.contains("#EXTINF"), let url = http.url {
                    warmUp.readyPath = url.path + (url.query.map { "?" + $0 } ?? "")
                    os_log("TV stream %{public}@ ready", String(hash.prefix(7)))
                } else {
                    warmUp.failed = true
                    os_log("TV stream %{public}@ failed", String(hash.prefix(7)))
                }
            }
        }.resume()
        return warmUp
    }

    private static func redirect(to location: String) -> Data {
        Data(("HTTP/1.1 302 Found\r\nLocation: \(location)\r\n" +
            "Content-Length: 0\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n").utf8)
    }

    /// Links that were red in the last check. Results last until Ace Link quits, and
    /// checking the channel again brings back links that work again.
    static func deadLinkIDs() -> Set<UUID> {
        Set(LinkChecker.shared.results.filter { $0.value.isDead }.keys)
    }

    static func playlist(channels: [Channel], host: String, hiding hidden: Set<UUID> = []) -> String {
        var out = "#EXTM3U\n"
        for channel in channels {
            let group = clean(channel.name)
            var logo = ""
            if case let .image(fileName) = channel.icon {
                logo = " tvg-logo=\"http://\(host):\(port)/icons/\(fileName)\""
            }
            for link in channel.links where !hidden.contains(link.id) {
                guard let stream = link.stream else { continue }
                let name = clean(link.name.isEmpty ? "Link" : link.name)
                let url = "http://\(host):\(port)/play/\(stream.param)/\(stream.hash).m3u8"
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
        let reasons = [200: "OK", 404: "Not Found", 502: "Bad Gateway", 504: "Gateway Timeout"]
        let reason = reasons[code] ?? "Error"
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
