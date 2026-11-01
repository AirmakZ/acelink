import Foundation
import os

enum Availability: Equatable {
    case checking
    /// Peers found and downloading fast enough to watch (KB/s measured).
    case available(Int)
    /// Peers found but too slow to watch smoothly, or stalled (KB/s measured).
    case slow(Int)
    case unavailable

    /// Sort order: working first, dead last.
    var rank: Int {
        switch self {
        case .available: return 0
        case .slow: return 1
        case .checking: return 2
        case .unavailable: return 3
        }
    }
}

private struct GetStreamResponse: Decodable {
    let response: Session?
    let error: String?

    struct Session: Decodable {
        let statURL: String
        let commandURL: String

        enum CodingKeys: String, CodingKey {
            case statURL = "stat_url"
            case commandURL = "command_url"
        }
    }
}

private struct StatResponse: Decodable {
    let response: Stats?

    struct Stats: Decodable {
        let peers: Int?
        let downloaded: Int?
    }
}

/// Checks all links of a channel at the same time against a running AceStream engine.
/// A link is unavailable without peers. With peers, the real download speed is measured
/// (the engine's own speed_down figure is a lagging average that can show hundreds of
/// KB/s for a stream that downloads nothing), and slow or stalled links are flagged.
final class LinkChecker: ObservableObject {
    static let shared = LinkChecker()

    /// How long each link gets to find a peer.
    static let timeout: TimeInterval = 45
    /// Below this the link is marked slow. Most live sports streams need 250–1000 KB/s.
    static let minimumKBps = 250
    /// The first seconds after peers are found are a burst that fills the buffer; skip them.
    static let warmUpSeconds: TimeInterval = 3
    static let measureSeconds: TimeInterval = 10

    /// Last result per link ID. Kept in memory until the app quits.
    @Published private(set) var results: [UUID: Availability] = [:]
    /// The channel being checked, if any. Only one check runs at a time.
    @Published private(set) var checkingChannelID: UUID?

    private var task: Task<Void, Never>?

    var isRunning: Bool { checkingChannelID != nil }

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
        let session = URLSession(configuration: .ephemeral)

        // A unique player id lets the engine run all checks side by side.
        let url = AppConstants.Docker.baseURL
            .appendingPathComponent("/ace/getstream")
            .appendingQuery(stream.param, stream.hash)
            .appendingQuery("format", "json")
            .appendingQuery("pid", UUID().uuidString)

        guard let (data, _) = try? await session.data(
            for: URLRequest(url: url, timeoutInterval: timeout)
        ),
            let start = try? JSONDecoder().decode(GetStreamResponse.self, from: data),
            let streamSession = start.response,
            let statURL = URL(string: streamSession.statURL)
        else {
            os_log("Link %{public}@ did not start.", String(stream.hash.prefix(7)))
            return .unavailable
        }

        func stats() async -> StatResponse.Stats? {
            guard let (data, _) = try? await session.data(from: statURL) else { return nil }
            return (try? JSONDecoder().decode(StatResponse.self, from: data))?.response
        }

        // 1. Wait for peers.
        var hasPeers = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let peers = await stats()?.peers, peers > 0 {
                hasPeers = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // 2. Measure how much it really downloads.
        var result = Availability.unavailable
        if hasPeers, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(warmUpSeconds * 1_000_000_000))
            let start = Date()
            let startBytes = await stats()?.downloaded ?? 0
            try? await Task.sleep(nanoseconds: UInt64(measureSeconds * 1_000_000_000))
            let endBytes = await stats()?.downloaded ?? startBytes
            let seconds = max(Date().timeIntervalSince(start), 1)
            let kbps = Int(Double(max(endBytes - startBytes, 0)) / 1024 / seconds)
            result = kbps >= minimumKBps ? .available(kbps) : .slow(kbps)
        }

        // Stop the test stream so it doesn't keep downloading.
        if let commandURL = URL(string: streamSession.commandURL) {
            _ = try? await session.data(from: commandURL.appendingQuery("method", "stop"))
        }
        os_log("Link %{public}@: %{public}@", String(stream.hash.prefix(7)), "\(result)")
        return result
    }
}
