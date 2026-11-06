import Foundation
import os

enum Availability: Equatable {
    case checking
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

    /// Sort order: working first, dead last.
    var rank: Int {
        switch self {
        case .available: return 0
        case .slow: return 1
        case .checking: return 2
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

    /// Last result per link ID. Kept in memory until the app quits.
    @Published private(set) var results: [UUID: Availability] = [:]
    /// The channel being checked, if any. Only one check runs at a time.
    @Published private(set) var checkingChannelID: UUID?

    private var task: Task<Void, Never>?

    var isRunning: Bool { checkingChannelID != nil }

    /// The most favorable result among a channel's links, for the sidebar: green if any
    /// link works, else orange if any is slow, else "checking" while some are still
    /// being tested, else red. Nil if none of its links has been checked.
    func bestResult(for channel: Channel) -> Availability? {
        channel.links.compactMap { results[$0.id] }.min { $0.rank < $1.rank }
    }

    /// Marks every link as "checking". Call before the engine is ready so the UI reacts at once.
    func begin(channel: Channel) {
        checkingChannelID = channel.id
        for link in channel.links {
            results[link.id] = .checking
        }
    }

    /// Runs the checks. `completion` gets link ID -> result, on the main thread,
    /// unless the check was cancelled.
    func run(channel: Channel, completion: @escaping ([UUID: Availability]) -> Void) {
        let links = channel.links
        os_log("Checking %d links of channel %{public}@…", links.count, channel.name)

        task = Task {
            let outcome = await withTaskGroup(
                of: (UUID, Availability).self
            ) { group -> [UUID: Availability] in
                for link in links {
                    group.addTask { (link.id, await Self.measure(link)) }
                }
                var outcome: [UUID: Availability] = [:]
                for await (id, result) in group {
                    outcome[id] = result
                    await MainActor.run {
                        guard self.checkingChannelID == channel.id else { return }
                        self.results[id] = result
                        if result.rank <= Availability.slow(0).rank,
                           let hash = links.first(where: { $0.id == id })?.stream?.hash {
                            ChannelStore.shared.markSeen(hash: hash)
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

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        checkingChannelID = nil
        results = results.filter { $0.value != .checking }
    }

    private static func measure(_ link: StreamLink) async -> Availability {
        guard let stream = link.stream else { return .unavailable }
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
            return .unavailable
        }

        // Read the video like a player does. The engine stops downloading once its
        // buffer (~10 MiB) is full and nobody reads it, so its own counters say little:
        // a link can fill the buffer at full speed and then never deliver any video.
        let reader = StreamReader()
        let player = URLSession(configuration: .ephemeral, delegate: reader, delegateQueue: nil)
        player.dataTask(with: URLRequest(url: playbackURL, timeoutInterval: timeout)).resume()

        var result: Availability
        let deadline = Date().addingTimeInterval(timeout)
        while reader.snapshot.firstByte == nil, !reader.snapshot.ended,
              Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let firstByte = reader.snapshot.firstByte {
            // The first seconds are the buffered burst; skip them, then measure.
            await sleep(until: firstByte.addingTimeInterval(warmUpSeconds))
            let begin = reader.snapshot
            await sleep(until: Date().addingTimeInterval(measureSeconds))
            let end = reader.snapshot
            let seconds = max(Date().timeIntervalSince(firstByte) - warmUpSeconds, 1)
            let kbps = Int(Double(end.bytes - begin.bytes) / 1024 / seconds)
            result = kbps >= minimumKBps ? .available(kbps) : .slow(kbps)
        } else {
            // No video. Tell "nobody shares it" apart from "shared but not playable".
            let peers = await stats(api, streamSession.statURL)?.peers ?? 0
            result = peers > 0 ? .noVideo : .unavailable
        }

        player.invalidateAndCancel()
        // Stop the test stream so it doesn't keep downloading.
        if let commandURL = URL(string: streamSession.commandURL) {
            _ = try? await api.data(from: commandURL.appendingQuery("method", "stop"))
        }
        os_log("Link %{public}@: %{public}@", short, "\(result)")
        return result
    }

    private static func sleep(until date: Date) async {
        while Date() < date, !Task.isCancelled {
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
