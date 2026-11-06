import Foundation
import Network
import os

/// "Share to TV": serves an M3U playlist of all channels on the local network so a TV
/// app (e.g. m3u-ip.tv) can play them. The streams come from the AceStream engine, which
/// AppDelegate keeps running while this is on; their HLS playlists and segments are relayed
/// through this server, so it knows which streams are still being watched (see `proxy`).
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
    /// Ends sessions nobody reads (see `sweepIdleSessions`).
    private var sweeper: DispatchSourceTimer?
    /// Fetches playlists and segments from the engine for the relay.
    private let engineSession = URLSession(configuration: .ephemeral)

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
            // Latency-critical keeps App Nap from slowing down the relay of the video.
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled,
                          .latencyCritical],
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
        sweeper?.cancel()
        sweeper = nil
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

        let sweeper = DispatchSource.makeTimerSource(queue: queue)
        sweeper.schedule(deadline: .now() + Self.sweepEvery, repeating: Self.sweepEvery)
        sweeper.setEventHandler { [weak self] in self?.sweepIdleSessions() }
        sweeper.resume()
        self.sweeper = sweeper
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
        let rawQuery = target.contains("?") ? String(target.drop { $0 != "?" }.dropFirst()) : nil
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

        if path.hasPrefix("/hls/") {
            return proxy(path: path, rawQuery: rawQuery, host: host, send: send)
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
    // Once ready, we redirect to our relay of the engine's HLS playlist (see `proxy`).

    /// How long to hold each request before answering "ask again".
    private static let holdSeconds: TimeInterval = 6
    /// Redirects before giving up (≈ 50 s), so a dead link fails in reasonable time.
    private static let maxHops = 8

    private final class WarmUp {
        let created = Date()
        var readyPath: String?
        var failed = false
        /// The session's stats, for the transfer rates shown in the list.
        var statURL: URL?
        /// The session's commands, to end it once nobody watches.
        var commandURL: URL?
        /// Last time a player (the Mac's or a TV) read the stream through the relay.
        var lastRead: Date?
        /// Last time a TV read it. The Mac's player comes through 127.0.0.1; a TV uses the
        /// Mac's network address.
        var lastTVRead: Date?

        func markRead(host: String) {
            lastRead = Date()
            if host != "127.0.0.1", host != "localhost" { lastTVRead = lastRead }
        }
    }

    /// A session nobody has read for this long is ended. The engine doesn't do it itself:
    /// it keeps downloading and segmenting a stream nobody watches.
    private static let idleSeconds: TimeInterval = 30
    private static let sweepEvery: DispatchTimeInterval = .seconds(10)

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
        let hash = String(parts[2].dropLast(".m3u8".count)).lowercased()
        guard hash.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            return send(Self.http(404, type: "text/plain", body: Data("Not found".utf8)))
        }

        let warmUp = warmUp(param: param, hash: hash, fresh: hop == 0)
        warmUp.markRead(host: host)
        let deadline = Date().addingTimeInterval(Self.holdSeconds)
        os_log("TV asks for %{public}@ (attempt %d)", String(hash.prefix(7)), hop + 1)

        func poll() {
            if warmUp.readyPath != nil {
                send(Self.redirect(to: "http://\(host):\(Self.port)/hls/\(hash)/index.m3u8"))
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

    /// Streams being watched through the relay (on a TV or the Mac): read recently.
    func activeStreamHashes() -> Set<String> {
        queue.sync {
            Set(warmUps.filter { _, warmUp in
                warmUp.readyPath != nil
                    && Date().timeIntervalSince(warmUp.lastRead ?? warmUp.created) < Self.idleSeconds
            }.keys)
        }
    }

    // MARK: - HLS relay

    // Players read a stream's playlist and segments through us rather than straight from
    // the engine. That costs a local hop, but it is the only way to know whether anyone is
    // still watching: the engine has no API for it, and keeps a session it isn't asked
    // about downloading forever. Paths:
    //   /hls/<hash>/index.m3u8          the session's playlist, segment URLs rewritten
    //   /hls/<hash>/seg/ace/...         a segment, fetched from the same engine path

    private func proxy(path: String, rawQuery: String?, host: String, send: @escaping (Data) -> Void) {
        let rest = path.dropFirst("/hls/".count)
        guard let slash = rest.firstIndex(of: "/") else { return send(Self.notFound) }
        let hash = String(rest[..<slash]).lowercased()
        let tail = String(rest[rest.index(after: slash)...])
        guard let warmUp = warmUps[hash], let readyPath = warmUp.readyPath,
              let playlistURL = URL(string: AppConstants.Docker.baseURL.absoluteString + readyPath)
        else {
            // The session ended. Players then ask for the channel again (/play/...).
            return send(Self.notFound)
        }
        warmUp.markRead(host: host)

        if tail == "index.m3u8" {
            relay(playlistURL, hash: hash, send: send) { body in
                Data(Self.rewrite(playlist: String(decoding: body, as: UTF8.self),
                                  from: playlistURL, hash: hash).utf8)
            }
        } else if tail.hasPrefix("seg/ace/"),
                  let segmentURL = URL(string: AppConstants.Docker.baseURL.absoluteString
                      + "/" + tail.dropFirst("seg/".count) + (rawQuery.map { "?" + $0 } ?? "")) {
            relay(segmentURL, hash: hash, send: send, type: "video/mp2t")
        } else {
            send(Self.notFound)
        }
    }

    /// Fetches `url` from the engine and passes it on, after `transform` if given.
    private func relay(
        _ url: URL, hash: String, send: @escaping (Data) -> Void,
        type: String = "application/vnd.apple.mpegurl", transform: ((Data) -> Data)? = nil
    ) {
        engineSession.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            guard status == 200, let data = data else {
                if status == 404 { self.forgetSession(hash: hash) } // The engine dropped it.
                return send(Self.http(status == 404 ? 404 : 502, type: "text/plain",
                                      body: Data("Stream unavailable".utf8)))
            }
            send(Self.http(200, type: type, body: transform?(data) ?? data))
        }.resume()
    }

    /// Points every segment of an engine playlist at the relay.
    static func rewrite(playlist: String, from playlistURL: URL, hash: String) -> String {
        playlist.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let url = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL
            else { return line }
            return "/hls/\(hash)/seg\(url.path)" + (url.query.map { "?" + $0 } ?? "")
        }.joined(separator: "\n")
    }

    /// Ends the sessions nobody has read for `idleSeconds`, and forgets failed warm-ups.
    private func sweepIdleSessions() {
        let now = Date()
        for (hash, warmUp) in warmUps {
            if warmUp.failed, now.timeIntervalSince(warmUp.created) > 60 {
                warmUps[hash] = nil
                continue
            }
            guard warmUp.readyPath != nil,
                  now.timeIntervalSince(warmUp.lastRead ?? warmUp.created) > Self.idleSeconds
            else { continue }
            os_log("Nobody watches %{public}@ any more; ending its session.", String(hash.prefix(7)))
            end(warmUp, hash: hash)
        }
    }

    /// Ends a stream's engine session and forgets it. Only touch on `queue`.
    private func end(_ warmUp: WarmUp, hash: String) {
        warmUps[hash] = nil
        guard let command = warmUp.commandURL else { return }
        engineSession.dataTask(with: command.appendingQuery("method", "stop")).resume()
    }

    /// The engine keeps one session per stream, and one stream per player id: asking for a
    /// stream under a new id cuts the session of the old one, and asking for another stream
    /// under the same id ends its previous session. So the id is derived from the stream.
    /// Everyone watching a stream (TVs and, while sharing, the Mac) reads the same session,
    /// and different streams never interfere.
    static func sessionPlayerID(hash: String) -> String {
        "acelink-\(hash.lowercased())"
    }

    /// The playlist the Mac's player opens to join the shared session of a stream.
    static func localPlayURL(for stream: StreamFile) -> URL {
        URL(string: "http://127.0.0.1:\(port)/play/\(stream.param)/\(stream.hash.lowercased()).m3u8")!
    }

    /// Starts (or reuses) loading a stream in the engine for the TV.
    private func warmUp(param: String, hash: String, fresh: Bool) -> WarmUp {
        if let existing = warmUps[hash],
           !(fresh && (existing.failed || Date().timeIntervalSince(existing.created) > 30)) {
            return existing
        }
        let warmUp = WarmUp()
        // Reads before the warm-up was renewed still count.
        warmUp.lastRead = warmUps[hash]?.lastRead
        warmUp.lastTVRead = warmUps[hash]?.lastTVRead
        warmUps[hash] = warmUp
        // A check testing this stream would cut the TV's session, and a check testing
        // every link at once would starve it.
        DispatchQueue.main.async {
            LinkChecker.shared.drop(hash: hash)
            LinkChecker.shared.throttle(to: LinkChecker.concurrencyWhilePlaying)
        }

        var components = URLComponents(
            url: AppConstants.Docker.baseURL.appendingPathComponent("/ace/manifest.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: param, value: hash),
            URLQueryItem(name: "pid", value: Self.sessionPlayerID(hash: hash))
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
                    self.fetchStatURL(for: warmUp, manifest: components)
                } else {
                    warmUp.failed = true
                    os_log("TV stream %{public}@ failed", String(hash.prefix(7)))
                }
            }
        }.resume()
        return warmUp
    }

    /// Asks the engine for the session's stats URL. The JSON form of the manifest under the
    /// same player id returns the same session, so this doesn't disturb the TV.
    private func fetchStatURL(for warmUp: WarmUp, manifest components: URLComponents) {
        var components = components
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { return }
        URLSession(configuration: .ephemeral).dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = object["response"] as? [String: Any],
                  let stat = (response["stat_url"] as? String).flatMap(URL.init(string:))
            else { return }
            let command = (response["command_url"] as? String).flatMap(URL.init(string:))
            self.queue.async {
                warmUp.statURL = stat
                warmUp.commandURL = command
            }
        }.resume()
    }

    /// Stats URLs of the shared sessions, by hash. Each stream has its own session (see
    /// `sessionPlayerID`), so several can be alive; `forgetSession` drops ended ones.
    func sessionStatURLs() -> [String: URL] {
        queue.sync { warmUps.compactMapValues(\.statURL) }
    }

    /// Forgets a stream whose session the engine has ended, so it's no longer polled and
    /// the next request starts a fresh one.
    func forgetSession(hash: String) {
        queue.async { self.warmUps[hash] = nil }
    }

    /// Ends a stream's shared session right away when the Mac stops playing it, unless a
    /// TV read it recently. If a TV was watching, the idle sweep ends it once the TV stops.
    func endSessionIfUnused(hash: String) {
        queue.async {
            guard let warmUp = self.warmUps[hash] else { return }
            if let tvRead = warmUp.lastTVRead,
               Date().timeIntervalSince(tvRead) < Self.idleSeconds { return }
            os_log("Ending shared session of %{public}@", String(hash.prefix(7)))
            self.end(warmUp, hash: hash)
        }
    }

    private static let notFound = http(404, type: "text/plain", body: Data("Not found".utf8))

    private static func redirect(to location: String) -> Data {
        Data(("HTTP/1.1 302 Found\r\nLocation: \(location)\r\n" +
            "Content-Length: 0\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n").utf8)
    }

    /// Links that were red in their last check: this session's result, else the one saved
    /// from an earlier launch. Checking the channel again brings back links that work again.
    /// Call on the main thread.
    static func deadLinkIDs() -> Set<UUID> {
        let current = LinkChecker.shared.results
        var dead: Set<UUID> = []
        for channel in ChannelStore.shared.channels {
            for link in channel.links where (current[link.id] ?? link.lastResult)?.isDead == true {
                dead.insert(link.id)
            }
        }
        return dead
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
