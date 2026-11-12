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
        LocalDeviceNames.shared.start() // To show which device watches each stream.
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
        let client = Self.clientAddress(of: connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.respond(to: request, client: client) { response in
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// The IP address a request came from ("127.0.0.1" for this Mac's own players).
    private static func clientAddress(of connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "?" }
        var address: String
        switch host {
        case let .ipv4(ipv4): address = "\(ipv4)"
        case let .ipv6(ipv6): address = "\(ipv6)"
        case let .name(name, _): address = name
        @unknown default: address = "\(host)"
        }
        address = address.components(separatedBy: "%")[0] // Drop an interface suffix.
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst(7)) } // IPv4-mapped.
        return address == "::1" ? "127.0.0.1" : address
    }

    private func respond(to request: String, client: String, send: @escaping (Data) -> Void) {
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
            // Read the channels on the main thread without waiting for it: the main thread
            // also waits on `queue` (viewers(), connecting()…), and waiting both ways deadlocks.
            DispatchQueue.main.async {
                let hidden = self.hideDeadLinks ? Self.deadLinkIDs() : []
                let body = Self.playlist(host: host, hiding: hidden)
                send(Self.http(200, type: "audio/x-mpegurl; charset=utf-8", body: Data(body.utf8)))
            }
            return
        }

        if path == EPGGuide.path {
            // The channels are read on the main thread (see above); the file is built here.
            DispatchQueue.main.async {
                let epg = EPGGuide.shared
                guard let guide = epg.guide, epg.isEnabled else { return send(Self.notFound) }
                let ids = Self.tvgIDs()
                self.queue.async {
                    send(Self.http(200, type: "application/xml; charset=utf-8",
                                   body: guide.xml(for: ids)))
                }
            }
            return
        }

        if path.hasPrefix("/play/") {
            let hop = query.first { $0.name == "hop" }?.value.flatMap(Int.init) ?? 0
            return play(path: path, hop: hop, host: host, client: client, send: send)
        }

        if path.hasPrefix("/hls/") {
            return proxy(path: path, rawQuery: rawQuery, client: client, send: send)
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

    /// A segment in a stream's history, numbered for players. Numbers keep growing across
    /// restarts, so players never see the playlist go back.
    private struct Segment {
        /// AceLinkUI's number for it, which players use (segment URLs end in "<sequence>.ts").
        let sequence: Int
        let duration: Double
        /// Where the engine serves it. Not unique: a restarted session numbers its segments
        /// from 0 again under the same path, so segments are keyed by `sequence` instead.
        let path: String
        /// The session it came from (see `WarmUp.session`).
        let session: Int
        /// First segment of a restarted session: a new source for players.
        let discontinuity: Bool
    }

    private final class WarmUp {
        let created = Date()
        /// The engine manifest request (id/infohash + pid), to start the session again.
        let manifest: URLComponents
        var readyPath: String?
        var failed = false
        /// The session's stats, for the transfer rates shown in the list.
        var statURL: URL?
        /// The session's commands, to end it once nobody watches.
        var commandURL: URL?
        /// Last time a player (the Mac's or a TV) read the stream through the relay.
        var lastRead: Date?
        /// Last time a TV (any other device) read it.
        var lastTVRead: Date?
        /// Who read it, by IP address ("127.0.0.1" is this Mac), and when last.
        var readers: [String: Date] = [:]

        func markRead(by client: String) {
            let now = Date()
            lastRead = now
            readers[client] = now
            if client != "127.0.0.1" { lastTVRead = now }
        }

        // The stream's own history of segments (see `refresh`). Players get playlists built
        // from it, never the engine's, so it survives the session dying.
        var history: [Segment] = []
        /// Discontinuities that slid out of the history, for EXT-X-DISCONTINUITY-SEQUENCE.
        var discontinuitiesDropped = 0
        var nextSequence = 0
        /// Newest engine media sequence taken from the current session.
        var lastEngineSequence: Int?
        /// The next segment taken starts a restarted session.
        var pendingDiscontinuity = false
        var targetDuration = 6
        /// Reads the engine playlist every few seconds while the stream is alive.
        var refresher: DispatchSourceTimer?
        /// Counts the engine sessions this stream has had (bumped by each restart).
        var session = 0
        /// Segment contents, by sequence, for every segment in the history.
        var segments: [Int: Data] = [:]
        var fetching: Set<Int> = []

        // Stall detection and restarts (see `restart`).
        /// Last time the history gained a segment.
        var lastProgress = Date()
        /// A new session is being started under the hood.
        var restarting = false
        var restartTimes: [Date] = []

        init(manifest: URLComponents) {
            self.manifest = manifest
        }
    }

    /// Seconds of segments listed in each playlist (at least `minimumSegments`). Generous on
    /// purpose: a restarted session arrives with ~30 s of segments at once, and the ones from
    /// before the restart that a TV hasn't fetched yet must still be listed, or it gives up.
    fileprivate static let windowSeconds: TimeInterval = 60
    /// Seconds kept in the history: the window shown, plus slack.
    private static let retention: TimeInterval = windowSeconds + 15
    /// A stream being read whose history gains no segment for this long is stuck.
    private static let stallSeconds: TimeInterval = 30
    private static let minimumSegments = 3
    private static let refreshEvery: DispatchTimeInterval = .seconds(2)

    /// Restarts allowed within `restartWindow` before giving up on a stream.
    private static let maxRestarts = 3
    private static let restartWindow: TimeInterval = 5 * 60

    /// A session nobody has read for this long is ended. The engine doesn't do it itself:
    /// it keeps downloading and segmenting a stream nobody watches.
    private static let idleSeconds: TimeInterval = 30
    private static let sweepEvery: DispatchTimeInterval = .seconds(10)

    /// Stream hash -> warm-up. Only touched on `queue`.
    private var warmUps: [String: WarmUp] = [:]

    private func play(
        path: String, hop: Int, host: String, client: String, send: @escaping (Data) -> Void
    ) {
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
        warmUp.markRead(by: client)
        let deadline = Date().addingTimeInterval(Self.holdSeconds)
        os_log("TV asks for %{public}@ (attempt %d)", String(hash.prefix(7)), hop + 1)

        func poll() {
            // Ready once there are segments to play.
            if warmUp.readyPath != nil, Self.window(of: warmUp) != nil {
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

    /// Who is watching each stream through the relay right now, by stream hash: IP
    /// addresses that read it within the idle window, "127.0.0.1" meaning this Mac.
    func viewers() -> [String: [String]] {
        queue.sync {
            let now = Date()
            return warmUps.compactMapValues { warmUp -> [String]? in
                guard warmUp.readyPath != nil else { return nil }
                let active = warmUp.readers
                    .filter { now.timeIntervalSince($0.value) < Self.idleSeconds }.keys.sorted()
                return active.isEmpty ? nil : active
            }
        }
    }

    /// Streams a TV (or the Mac's player) is waiting for, by hash: who asked and what's going
    /// on, until they play. Restarting streams count too.
    func connecting() -> [String: (readers: [String], message: String)] {
        queue.sync {
            let now = Date()
            return warmUps.compactMapValues { warmUp in
                let starting = warmUp.readyPath == nil && !warmUp.failed
                guard starting || warmUp.restarting else { return nil }
                let readers = warmUp.readers
                    .filter { now.timeIntervalSince($0.value) < Self.idleSeconds }.keys.sorted()
                let seconds = Int(now.timeIntervalSince(warmUp.created))
                return (readers, warmUp.restarting ? "Reconnecting…" : "Connecting… \(seconds) s")
            }
        }
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
    // still watching (the engine has no API for it, and keeps a session it isn't asked
    // about downloading forever). It also lets a stream survive its session dying. Paths:
    //   /hls/<hash>/index.m3u8          a playlist built from the stream's history
    //   /hls/<hash>/seg/<sequence>.ts   a segment by AceLinkUI's number, from the cache (or
    //                                   the engine, while its session is the current one)

    private func proxy(
        path: String, rawQuery: String?, client: String, send: @escaping (Data) -> Void
    ) {
        let rest = path.dropFirst("/hls/".count)
        guard let slash = rest.firstIndex(of: "/") else { return send(Self.notFound) }
        let hash = String(rest[..<slash]).lowercased()
        let tail = String(rest[rest.index(after: slash)...])
        guard let warmUp = warmUps[hash], warmUp.readyPath != nil else {
            return send(Self.notFound) // The stream ended.
        }
        warmUp.markRead(by: client)

        if tail == "index.m3u8" {
            // Built from the history, so it never fails: players give up on a playlist error
            // for good (seen on TVs). If the session is restarting, it just doesn't grow.
            let body = Self.playlist(of: warmUp, hash: hash)
            send(Self.http(200, type: "application/vnd.apple.mpegurl", body: Data(body.utf8)))
        } else if tail.hasPrefix("seg/"), tail.hasSuffix(".ts"),
                  let sequence = Int(tail.dropFirst("seg/".count).dropLast(".ts".count)) {
            if let cached = warmUp.segments[sequence] {
                return send(Self.http(200, type: "video/mp2t", body: cached))
            }
            // Not fetched yet: only the current session can still give it. An older session's
            // path now leads to a different segment of the new one.
            guard let segment = warmUp.history.first(where: { $0.sequence == sequence }),
                  segment.session == warmUp.session, !warmUp.restarting,
                  let url = URL(string: AppConstants.Docker.baseURL.absoluteString + segment.path)
            else { return send(Self.notFound) }
            engineSession.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { data, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data else {
                    return send(Self.http(404, type: "text/plain", body: Data("Not found".utf8)))
                }
                self.queue.async {
                    if warmUp.history.contains(where: { $0.sequence == sequence }) {
                        warmUp.segments[sequence] = data
                    }
                }
                send(Self.http(200, type: "video/mp2t", body: data))
            }.resume()
        } else {
            send(Self.notFound)
        }
    }

    /// The segments a player gets: the last `windowSeconds` of the history. Nil while there
    /// are none yet. On `queue`.
    private static func window(of warmUp: WarmUp) -> ArraySlice<Segment>? {
        let eligible = warmUp.history[...]
        var start = eligible.endIndex
        var shown: TimeInterval = 0
        while start > eligible.startIndex,
              shown < windowSeconds || eligible.endIndex - start < minimumSegments {
            start -= 1
            shown += eligible[start].duration
        }
        let window = eligible[start...]
        return window.count >= min(minimumSegments, warmUp.history.count) && !window.isEmpty
            ? window : nil
    }

    /// A live HLS playlist built from the stream's history. Numbering continues across
    /// restarts, with discontinuities marking a new source.
    private static func playlist(of warmUp: WarmUp, hash: String) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(warmUp.targetDuration)"]
        guard let window = window(of: warmUp), let first = window.first
        else {
            // Nothing yet: an empty live playlist makes players wait and ask again.
            lines.append("#EXT-X-MEDIA-SEQUENCE:\(warmUp.nextSequence)")
            return lines.joined(separator: "\n") + "\n"
        }
        let earlierDiscontinuities = warmUp.history.prefix { $0.sequence < first.sequence }
            .filter(\.discontinuity).count
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(first.sequence)")
        lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(warmUp.discontinuitiesDropped + earlierDiscontinuities)")
        for segment in window {
            if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append("/hls/\(hash)/seg/\(segment.sequence).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the engine playlist every few seconds, appends new segments to the history and
    /// fetches them into the cache. Runs from the moment the session is ready.
    private func startRefreshing(_ warmUp: WarmUp, hash: String) {
        warmUp.refresher?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.refreshEvery)
        timer.setEventHandler { [weak self, weak warmUp] in
            guard let self = self, let warmUp = warmUp else { return }
            self.refresh(warmUp, hash: hash)
        }
        timer.resume()
        warmUp.refresher = timer
    }

    private func refresh(_ warmUp: WarmUp, hash: String) {
        guard !warmUp.restarting, let readyPath = warmUp.readyPath,
              let playlistURL = URL(string: AppConstants.Docker.baseURL.absoluteString + readyPath)
        else { return }
        engineSession.dataTask(with: URLRequest(url: playlistURL, timeoutInterval: 10)) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                // Only news about the current session counts (a restart may have replaced it).
                guard warmUp.readyPath == readyPath, !warmUp.restarting else { return }
                if status == 404 {
                    self.sessionGone(hash: hash) { $0 === warmUp }
                } else if status == 200, let data = data {
                    self.ingest(String(decoding: data, as: UTF8.self), from: playlistURL, into: warmUp)
                }
            }
        }.resume()
    }

    /// Takes the segments of an engine playlist that are new into the history. On `queue`.
    private func ingest(_ playlist: String, from playlistURL: URL, into warmUp: WarmUp) {
        var engineSequence = 0
        var duration: Double?
        var added = false
        for raw in playlist.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                engineSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                warmUp.targetDuration = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 6
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#") {
                defer { engineSequence += 1; duration = nil }
                guard engineSequence > (warmUp.lastEngineSequence ?? -1),
                      let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL
                else { continue }
                let segment = Segment(
                    sequence: warmUp.nextSequence, duration: duration ?? Double(warmUp.targetDuration),
                    path: url.path + (url.query.map { "?" + $0 } ?? ""), session: warmUp.session,
                    discontinuity: warmUp.pendingDiscontinuity
                )
                warmUp.history.append(segment)
                warmUp.nextSequence += 1
                warmUp.pendingDiscontinuity = false
                warmUp.lastEngineSequence = engineSequence
                added = true
                fetchSegment(segment, into: warmUp)
            }
        }
        guard added else { return }
        warmUp.lastProgress = Date()
        // Keep `retention` seconds, and the cache to match.
        var kept: TimeInterval = 0
        var firstKept = warmUp.history.endIndex
        while firstKept > warmUp.history.startIndex, kept < Self.retention {
            firstKept -= 1
            kept += warmUp.history[firstKept].duration
        }
        let dropped = warmUp.history[..<firstKept]
        warmUp.discontinuitiesDropped += dropped.filter(\.discontinuity).count
        for segment in dropped { warmUp.segments[segment.sequence] = nil }
        warmUp.history.removeFirst(firstKept)
    }

    /// Fetches a segment into the cache as soon as the history has it, so it survives the
    /// session dying before players ask for it (a missing segment makes TVs give up).
    private func fetchSegment(_ segment: Segment, into warmUp: WarmUp) {
        let sequence = segment.sequence
        guard warmUp.segments[sequence] == nil, !warmUp.fetching.contains(sequence),
              let url = URL(string: AppConstants.Docker.baseURL.absoluteString + segment.path)
        else { return }
        warmUp.fetching.insert(sequence)
        engineSession.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            self.queue.async {
                warmUp.fetching.remove(sequence)
                // Only if its session is still the one at that path; else it's another segment.
                guard ok, let data = data, segment.session == warmUp.session,
                      warmUp.history.contains(where: { $0.sequence == sequence })
                else { return }
                warmUp.segments[sequence] = data
            }
        }.resume()
    }

    /// Starts a stuck stream's session again under the hood: players keep the same playlist
    /// URL, which keeps serving the history, then the new session's segments after a
    /// discontinuity. Gives up (ends the session) after `maxRestarts` within
    /// `restartWindow`. Only call on `queue`.
    private func restart(_ warmUp: WarmUp, hash: String, reason: String) {
        let now = Date()
        warmUp.restartTimes = warmUp.restartTimes.filter { now.timeIntervalSince($0) < Self.restartWindow }
        guard warmUp.restartTimes.count < Self.maxRestarts else {
            os_log("Stream %{public}@ keeps getting stuck; ending its session.", String(hash.prefix(7)))
            return end(warmUp, hash: hash)
        }
        warmUp.restartTimes.append(now)
        warmUp.restarting = true
        warmUp.session += 1
        // The newest segments of the old session that weren't fetched in time are gone with
        // it: unlist them (and reuse their numbers), so no player asks for one and gets a 404.
        while let last = warmUp.history.last, warmUp.segments[last.sequence] == nil {
            warmUp.history.removeLast()
            warmUp.nextSequence = last.sequence
        }
        warmUp.fetching.removeAll()
        os_log("Stream %{public}@ is stuck (%{public}@); restarting its session (%d/%d).",
               String(hash.prefix(7)), reason, warmUp.restartTimes.count, Self.maxRestarts)
        let command = warmUp.commandURL
        warmUp.statURL = nil
        warmUp.commandURL = nil
        // End the old session first: under the same player id, asking again would only
        // return it.
        guard let command = command else { return startSession(for: warmUp, hash: hash) }
        engineSession.dataTask(with: command.appendingQuery("method", "stop")) { _, _, _ in
            self.queue.async { self.startSession(for: warmUp, hash: hash) }
        }.resume()
    }

    /// The engine no longer knows a stream's session. If someone is watching, start it again;
    /// otherwise forget it. `isCurrent` checks that the news is about the session in use,
    /// not one already replaced by a restart.
    private func sessionGone(hash: String, isCurrent: @escaping (WarmUp) -> Bool) {
        queue.async {
            guard let warmUp = self.warmUps[hash], !warmUp.restarting, isCurrent(warmUp)
            else { return }
            if Date().timeIntervalSince(warmUp.lastRead ?? warmUp.created) < Self.idleSeconds,
               warmUp.readyPath != nil {
                self.restart(warmUp, hash: hash, reason: "the engine ended its session")
            } else {
                self.end(warmUp, hash: hash)
            }
        }
    }

    /// Ends the sessions nobody has read for `idleSeconds`, restarts stuck ones, and forgets
    /// failed warm-ups.
    private func sweepIdleSessions() {
        let now = Date()
        for (hash, warmUp) in warmUps {
            if warmUp.failed, now.timeIntervalSince(warmUp.created) > 60 {
                warmUps[hash] = nil
                continue
            }
            guard warmUp.readyPath != nil, !warmUp.restarting else { continue }
            if now.timeIntervalSince(warmUp.lastRead ?? warmUp.created) > Self.idleSeconds {
                os_log("Nobody watches %{public}@ any more; ending its session.", String(hash.prefix(7)))
                end(warmUp, hash: hash)
            } else if now.timeIntervalSince(warmUp.lastProgress) > Self.stallSeconds {
                restart(warmUp, hash: hash, reason: "no new video for \(Int(Self.stallSeconds)) s")
            }
        }
    }

    /// Ends a stream's engine session and forgets it. Only touch on `queue`.
    private func end(_ warmUp: WarmUp, hash: String) {
        warmUp.refresher?.cancel()
        warmUp.refresher = nil
        if warmUps[hash] === warmUp { warmUps[hash] = nil }
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
        // A ready stream is kept as is: players reading it rely on its numbering. One that
        // got stuck is restarted by the sweep, and only a failed one is tried again.
        if let existing = warmUps[hash], !(fresh && existing.failed) {
            return existing
        }
        var manifest = URLComponents(
            url: AppConstants.Docker.baseURL.appendingPathComponent("/ace/manifest.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        manifest.queryItems = [
            URLQueryItem(name: param, value: hash),
            URLQueryItem(name: "pid", value: Self.sessionPlayerID(hash: hash))
        ]
        let warmUp = WarmUp(manifest: manifest)
        // Reads before the warm-up was renewed still count.
        warmUp.lastRead = warmUps[hash]?.lastRead
        warmUp.lastTVRead = warmUps[hash]?.lastTVRead
        warmUp.readers = warmUps[hash]?.readers ?? [:]
        warmUps[hash] = warmUp
        // A check testing this stream would cut the TV's session, and a check testing
        // every link at once would starve it.
        DispatchQueue.main.async {
            LinkChecker.shared.drop(hash: hash)
            LinkChecker.shared.throttle(to: LinkChecker.concurrencyWhilePlaying)
        }

        startSession(for: warmUp, hash: hash)
        return warmUp
    }

    /// Asks the engine for the stream's session and waits until it has video. Only call on
    /// `queue`. Used for the first start and for restarts.
    private func startSession(for warmUp: WarmUp, hash: String) {
        let request = URLRequest(
            url: warmUp.manifest.url!,
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
                    warmUp.lastProgress = Date()
                    warmUp.lastEngineSequence = nil // A new session numbers from its own start.
                    if warmUp.restarting {
                        warmUp.restarting = false
                        warmUp.pendingDiscontinuity = true
                        os_log("TV stream %{public}@ restarted", String(hash.prefix(7)))
                    } else {
                        os_log("TV stream %{public}@ ready", String(hash.prefix(7)))
                    }
                    self.startRefreshing(warmUp, hash: hash)
                    self.fetchStatURL(for: warmUp, manifest: warmUp.manifest)
                } else if warmUp.restarting {
                    os_log("TV stream %{public}@ didn't come back; giving up.", String(hash.prefix(7)))
                    self.end(warmUp, hash: hash)
                } else {
                    warmUp.failed = true
                    os_log("TV stream %{public}@ failed", String(hash.prefix(7)))
                }
            }
        }.resume()
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
    func forgetSession(hash: String, statURL: URL) {
        sessionGone(hash: hash) { $0.statURL == statURL }
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
        for channel in ChannelStore.shared.channels + RemoteList.shared.store.channels {
            for link in channel.links where (current[link.id] ?? link.lastResult)?.isDead == true {
                dead.insert(link.id)
            }
        }
        return dead
    }

    /// Put before the remote list's channel names on the TV, to tell them from yours.
    static let remotePrefix = "R - "

    /// Your channels, then the remote list's (prefixed with `remotePrefix`).
    /// Call on the main thread.
    static func playlist(host: String, hiding hidden: Set<UUID> = []) -> String {
        header(host: host)
            + entries(channels: ChannelStore.shared.channels, host: host, hiding: hidden)
            + entries(channels: RemoteList.shared.store.channels, host: host, hiding: hidden,
                      prefix: remotePrefix)
    }

    /// Points TV apps to the guide when there is one (`url-tvg`, and `x-tvg-url` for the apps
    /// that read that name instead).
    private static func header(host: String) -> String {
        let epg = EPGGuide.shared
        guard epg.isEnabled, epg.guide != nil else { return "#EXTM3U\n" }
        let url = "http://\(host):\(port)\(EPGGuide.path)"
        return "#EXTM3U url-tvg=\"\(url)\" x-tvg-url=\"\(url)\"\n"
    }

    /// The guide channels of every link in the playlist. Call on the main thread.
    private static func tvgIDs() -> Set<String> {
        var ids: Set<String> = []
        for channel in ChannelStore.shared.channels + RemoteList.shared.store.channels {
            for link in channel.links {
                if let id = EPGGuide.shared.tvgID(channel: channel, link: link) { ids.insert(id) }
            }
        }
        return ids
    }

    private static func entries(
        channels: [Channel], host: String, hiding hidden: Set<UUID>, prefix: String = ""
    ) -> String {
        var out = ""
        for channel in channels {
            let group = prefix + clean(channel.name)
            var logo = ""
            if case let .image(fileName) = channel.icon {
                logo = " tvg-logo=\"http://\(host):\(port)/icons/\(fileName)\""
            }
            for link in channel.links where !hidden.contains(link.id) {
                guard let stream = link.stream else { continue }
                let name = clean(link.name.isEmpty ? "Link" : link.name)
                let url = "http://\(host):\(port)/play/\(stream.param)/\(stream.hash).m3u8"
                let tvgID = EPGGuide.shared.tvgID(channel: channel, link: link)
                    .map { " tvg-id=\"\(clean($0))\"" } ?? ""
                out += "#EXTINF:-1\(tvgID)\(logo) group-title=\"\(group)\"," +
                    "\(group) · \(name)\n\(url)\n"
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

/// Friendly names of the devices on the local network, from what they announce over Bonjour
/// (e.g. "Samsung BU8000 43 TV"), by IPv4 address. Reverse DNS gives nothing on most home
/// networks. Resolving only asks mDNS for the address: it doesn't connect to the device.
final class LocalDeviceNames: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = LocalDeviceNames()

    /// IPv4 address -> name.
    @Published private(set) var names: [String: String] = [:]

    /// Service types to browse, the one with the most descriptive names first.
    private static let types = [
        "_airplay._tcp.", "_googlecast._tcp.", "_raop._tcp.",
        "_companion-link._tcp.", "_device-info._tcp.", "_smb._tcp."
    ]

    private var browsers: [NetServiceBrowser] = []
    /// Services being resolved; NetService must be kept alive until it calls back.
    private var resolving: [NetService] = []
    /// IP -> index in `types` of the service its current name came from.
    private var rank: [String: Int] = [:]

    /// Starts browsing. Call on the main thread (results arrive on its run loop).
    func start() {
        guard browsers.isEmpty else { return }
        for type in Self.types {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func netServiceBrowser(_: NetServiceBrowser, didFind service: NetService, moreComing _: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let name = Self.friendlyName(of: sender)
        let serviceRank = Self.types.firstIndex(of: sender.type) ?? Self.types.count
        for ip in Self.ipv4Addresses(sender.addresses ?? []) {
            if let current = rank[ip], current <= serviceRank { continue }
            rank[ip] = serviceRank
            names[ip] = name
        }
        finish(sender)
    }

    func netService(_ sender: NetService, didNotResolve _: [String: NSNumber]) {
        finish(sender)
    }

    private func finish(_ service: NetService) {
        service.stop()
        resolving.removeAll { $0 === service }
    }

    private static func friendlyName(of service: NetService) -> String {
        let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        if service.type.hasPrefix("_googlecast"), let fn = txt["fn"].flatMap({ String(data: $0, encoding: .utf8) }) {
            return fn // Cast devices announce an id; their name is in the TXT record.
        }
        if service.type.hasPrefix("_raop"), let at = service.name.firstIndex(of: "@") {
            return String(service.name[service.name.index(after: at)...]) // "A1B2C3D4E5F6@Name"
        }
        return service.name
    }

    private static func ipv4Addresses(_ addresses: [Data]) -> [String] {
        addresses.compactMap { data -> String? in
            data.withUnsafeBytes { raw -> String? in
                guard raw.count >= MemoryLayout<sockaddr_in>.size,
                      raw.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET)
                else { return nil }
                var address = raw.load(as: sockaddr_in.self).sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil
                else { return nil }
                return String(cString: buffer)
            }
        }
    }
}
