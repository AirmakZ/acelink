import Foundation
import os

enum Availability: Equatable, Codable {
    /// Being tested right now.
    case checking
    /// Waiting in the check's queue for its turn.
    case queued
    /// Peers found and downloading fast enough to watch (KB/s measured).
    case available(Int)
    /// Peers found but too slow to watch smoothly, or stalled (KB/s measured).
    case slow(Int)
    /// Peers found, but no video arrived in time: it won't play.
    case noVideo
    /// No peers: nobody is sharing it.
    case unavailable

    /// Red: it won't play.
    var isDead: Bool { rank == 3 }

    /// Part of a check that hasn't finished: being tested or waiting for its turn.
    var isPending: Bool { self == .checking || self == .queued }

    /// Sort order: working first, dead last.
    var rank: Int {
        switch self {
        case .available: return 0
        case .slow: return 1
        case .checking, .queued: return 2
        case .noVideo, .unavailable: return 3
        }
    }
}

private struct GetStreamResponse: Decodable {
    let response: Session?
    let error: String?

    struct Session: Decodable {
        let statURL: String
        let commandURL: String
        let playbackURL: String

        enum CodingKeys: String, CodingKey {
            case statURL = "stat_url"
            case commandURL = "command_url"
            case playbackURL = "playback_url"
        }
    }
}

private struct StatResponse: Decodable {
    let response: Stats?

    struct Stats: Decodable {
        let peers: Int?
    }
}

/// Checks all links of a channel at the same time against a running AceStream engine.
/// Each link is opened and read like a player would, and the speed at which video
/// arrives is measured. Links without video are dead; slow or stalled ones are flagged.
final class LinkChecker: ObservableObject {
    static let shared = LinkChecker()

    /// How long each link gets to deliver its first video.
    static let timeout: TimeInterval = 45
    /// Below this the link is marked slow. Most live sports streams need 250–1000 KB/s.
    static let minimumKBps = 250
    /// The first seconds of video are the engine's buffer arriving all at once; skip them.
    static let warmUpSeconds: TimeInterval = 3
    static let measureSeconds: TimeInterval = 10
    /// Links tested at the same time while something plays, so the check doesn't starve
    /// it of bandwidth and engine time. With nothing playing, all at once.
    static let concurrencyWhilePlaying = 3

    /// Last result per link ID. Kept in memory until the app quits.
    @Published private(set) var results: [UUID: Availability] = [:]
    /// Peers the engine reported per link, read right after its speed was measured.
    @Published private(set) var peers: [UUID: Int] = [:]
    /// The channel being checked, if any. Only one check runs at a time.
    @Published private(set) var checkingChannelID: UUID?

    private var task: Task<Void, Never>?
    /// Which tests run, may start, are dropped or must be redone. Shared with the check task.
    private let state = CheckState()
    /// The links of the running check, to find them by stream.
    private var checkingLinks: [StreamLink] = []

    var isRunning: Bool { checkingChannelID != nil }

    /// A channel's result for the sidebar: "checking" (or "waiting" if all that's left is
    /// queued) until every link has its result, then the most favorable one: green if any
    /// link works, else orange if any is slow, else red. Nil if none has been checked.
    /// Pending wins over a link that already works, so the sidebar keeps spinning for as
    /// long as the check runs instead of turning green with the first good link.
    func bestResult(for channel: Channel) -> Availability? {
        let channelResults = channel.links.compactMap { results[$0.id] }
        if channelResults.contains(.checking) { return .checking }
        if channelResults.contains(.queued) { return .queued }
        return channelResults.min { $0.rank < $1.rank }
    }

    /// Like `bestResult`, from the results saved by earlier checks (shown as a ring).
    func bestPreviousResult(for channel: Channel) -> Availability? {
        channel.links.compactMap(\.lastResult).min { $0.rank < $1.rank }
    }

    /// Marks every link as "checking". Call before the engine is ready so the UI reacts at once.
    func begin(channel: Channel) {
        checkingChannelID = channel.id
        checkingLinks = channel.links
        for link in channel.links {
            results[link.id] = .checking
            peers[link.id] = nil
        }
    }

    /// Runs the checks, at most `maxConcurrent` links at a time. `completion` gets link
    /// ID -> result, on the main thread, unless the check was cancelled.
    func run(
        channel: Channel, maxConcurrent: Int = .max,
        completion: @escaping ([UUID: Availability]) -> Void
    ) {
        let links = channel.links
        let byID = Dictionary(links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let state = self.state
        state.reset(limit: maxConcurrent)
        // Links beyond the first batch wait for their turn (see `fill`).
        for link in links.dropFirst(maxConcurrent) where results[link.id] == .checking {
            results[link.id] = .queued
        }
        func show(_ availability: Availability, for id: UUID) {
            DispatchQueue.main.async {
                guard self.checkingChannelID == channel.id, self.results[id]?.isPending == true
                else { return }
                self.results[id] = availability
            }
        }
        os_log("Checking %d links of channel %{public}@ (%d at a time)…",
               links.count, channel.name, min(maxConcurrent, links.count))

        task = Task {
            let outcome = await withTaskGroup(
                of: (UUID, Availability, Int?).self
            ) { group -> [UUID: Availability] in
                // Links still to test. Tests interrupted by `throttle` come back at the end.
                var pending = links
                func fill() {
                    while !pending.isEmpty, state.canStart() {
                        let link = pending.removeFirst()
                        guard state.start(link.id) else { continue } // Dropped meanwhile.
                        show(.checking, for: link.id)
                        group.addTask {
                            let (result, peers) = await Self.measure(link) { state.shouldStop(link.id) }
                            return (link.id, result, peers)
                        }
                    }
                }
                fill()

                var outcome: [UUID: Availability] = [:]
                for await (id, result, peers) in group {
                    let fate = state.finish(id)
                    if fate == .redo, let link = byID[id] {
                        pending.append(link)
                        show(.queued, for: id)
                    }
                    fill()
                    guard fate == .done else { continue }
                    outcome[id] = result
                    await MainActor.run {
                        guard self.checkingChannelID == channel.id else { return }
                        self.results[id] = result
                        self.peers[id] = peers
                        if let hash = links.first(where: { $0.id == id })?.stream?.hash {
                            TransferMonitor.shared.forgetLastRate(hash: hash)
                            ChannelStore.shared.record(result, peers: peers, hash: hash)
                        }
                    }
                }
                return outcome
            }

            await MainActor.run {
                guard !Task.isCancelled, self.checkingChannelID == channel.id else { return }
                self.checkingChannelID = nil
                self.task = nil
                completion(outcome)
            }
        }
    }

    /// Takes a stream out of the running check because it is about to play.
    func drop(hash: String) {
        guard isRunning else { return }
        let hash = hash.lowercased()
        for link in checkingLinks
            where link.stream?.hash.lowercased() == hash && results[link.id]?.isPending == true {
            os_log("Leaving %{public}@ out of the check: it is starting to play.",
                   String(hash.prefix(7)))
            state.drop(link.id)
            results[link.id] = nil
        }
    }

    /// Lowers how many links are tested at once, e.g. because something started playing.
    /// Running tests beyond the limit are stopped (ending their sessions) and redone later.
    func throttle(to limit: Int) {
        guard isRunning else { return }
        let interrupted = state.throttle(to: limit)
        if interrupted > 0 {
            os_log("Something started playing: checking %d at a time, %d test(s) to redo.",
                   limit, interrupted)
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        checkingChannelID = nil
        results = results.filter { !$0.value.isPending }
        peers = peers.filter { results[$0.key] != nil }
    }

    /// `stop` ends the test early (its result is then ignored). Also returns the peers the
    /// engine reported, if they could be read.
    private static func measure(
        _ link: StreamLink, stop: @escaping () -> Bool
    ) async -> (Availability, Int?) {
        guard let stream = link.stream else { return (.unavailable, nil) }
        let short = String(stream.hash.prefix(7))
        let api = URLSession(configuration: .ephemeral)
        defer { api.invalidateAndCancel() }

        // A unique player id lets the engine run all checks side by side.
        let url = AppConstants.Docker.baseURL
            .appendingPathComponent("/ace/getstream")
            .appendingQuery(stream.param, stream.hash)
            .appendingQuery("format", "json")
            .appendingQuery("pid", UUID().uuidString)

        guard let (data, _) = try? await api.data(
            for: URLRequest(url: url, timeoutInterval: timeout)
        ),
            let start = try? JSONDecoder().decode(GetStreamResponse.self, from: data),
            let streamSession = start.response,
            let playbackURL = URL(string: streamSession.playbackURL)
        else {
            os_log("Link %{public}@ did not start.", short)
            return (.unavailable, nil)
        }

        // Read the video like a player does. The engine stops downloading once its
        // buffer (~10 MiB) is full and nobody reads it, so its own counters say little:
        // a link can fill the buffer at full speed and then never deliver any video.
        let reader = StreamReader()
        let player = URLSession(configuration: .ephemeral, delegate: reader, delegateQueue: nil)
        player.dataTask(with: URLRequest(url: playbackURL, timeoutInterval: timeout)).resume()

        var result: Availability
        var peers: Int?
        let deadline = Date().addingTimeInterval(timeout)
        while reader.snapshot.firstByte == nil, !reader.snapshot.ended,
              Date() < deadline, !Task.isCancelled, !stop() {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let firstByte = reader.snapshot.firstByte {
            // The first seconds are the buffered burst; skip them, then measure.
            await sleep(until: firstByte.addingTimeInterval(warmUpSeconds), stop: stop)
            let begin = reader.snapshot
            await sleep(until: Date().addingTimeInterval(measureSeconds), stop: stop)
            let end = reader.snapshot
            let seconds = max(Date().timeIntervalSince(firstByte) - warmUpSeconds, 1)
            let kbps = Int(Double(end.bytes - begin.bytes) / 1024 / seconds)
            result = kbps >= minimumKBps ? .available(kbps) : .slow(kbps)
            // Peers are read after the speed, while the session is still open.
            peers = await stats(api, streamSession.statURL)?.peers
        } else {
            // No video. Tell "nobody shares it" apart from "shared but not playable".
            peers = await stats(api, streamSession.statURL)?.peers
            result = (peers ?? 0) > 0 ? .noVideo : .unavailable
        }

        player.invalidateAndCancel()
        // Stop the test stream so it doesn't keep downloading.
        if let commandURL = URL(string: streamSession.commandURL) {
            _ = try? await api.data(from: commandURL.appendingQuery("method", "stop"))
        }
        os_log("Link %{public}@: %{public}@, peers: %d", short, "\(result)", peers ?? -1)
        return (result, peers)
    }

    private static func sleep(until date: Date, stop: () -> Bool) async {
        while Date() < date, !Task.isCancelled, !stop() {
            try? await Task.sleep(nanoseconds: UInt64(min(date.timeIntervalSinceNow, 0.5) * 1e9))
        }
    }

    private static func stats(_ session: URLSession, _ statURL: String) async -> StatResponse.Stats? {
        guard let url = URL(string: statURL),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return (try? JSONDecoder().decode(StatResponse.self, from: data))?.response
    }
}

/// Counts the bytes of a stream as they arrive.
private final class StreamReader: NSObject, URLSessionDataDelegate {
    struct Snapshot {
        var bytes = 0
        var firstByte: Date?
        var ended = false
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if state.firstByte == nil, !data.isEmpty { state.firstByte = Date() }
        state.bytes += data.count
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError _: Error?) {
        lock.lock()
        defer { lock.unlock() }
        state.ended = true
    }
}

/// The scheduling state of a running check, shared between the main thread (which drops
/// links and lowers the limit) and the check task.
private final class CheckState: @unchecked Sendable {
    enum Fate { case done, dropped, redo }

    private let lock = NSLock()
    private var limit = Int.max
    /// Running tests, oldest first.
    private var running: [UUID] = []
    private var dropped: Set<UUID> = []
    private var redo: Set<UUID> = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func reset(limit: Int) {
        locked {
            self.limit = max(limit, 1)
            running = []
            dropped = []
            redo = []
        }
    }

    func canStart() -> Bool { locked { running.count < limit } }

    /// Marks a test as running. False if the link was dropped and must not be tested.
    func start(_ id: UUID) -> Bool {
        locked {
            guard !dropped.contains(id) else { return false }
            running.append(id)
            return true
        }
    }

    /// Whether a running test should stop early (its result is then ignored).
    func shouldStop(_ id: UUID) -> Bool { locked { dropped.contains(id) || redo.contains(id) } }

    func finish(_ id: UUID) -> Fate {
        locked {
            running.removeAll { $0 == id }
            if dropped.contains(id) { return .dropped }
            if redo.remove(id) != nil { return .redo }
            return .done
        }
    }

    func drop(_ id: UUID) { _ = locked { dropped.insert(id) } }

    /// Lowers the limit and marks the newest running tests beyond it to be redone, keeping
    /// the oldest, which are closest to finishing. Returns how many were interrupted.
    func throttle(to newLimit: Int) -> Int {
        locked {
            limit = min(limit, max(newLimit, 1))
            let extra = running.filter { !dropped.contains($0) && !redo.contains($0) }
                .dropFirst(limit)
            redo.formUnion(extra)
            return extra.count
        }
    }
}
