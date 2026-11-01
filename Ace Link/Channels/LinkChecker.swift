import Foundation
import os

enum Availability: Equatable {
    case checking
    case available
    case unavailable
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
    }
}

/// Checks all links of a channel at the same time against a running AceStream engine.
/// A link counts as available when the engine finds at least one peer for it, which is
/// the same test the app uses before opening a stream in the player.
final class LinkChecker: ObservableObject {
    static let shared = LinkChecker()

    /// How long each link gets to find a peer.
    static let timeout: TimeInterval = 45

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

    /// Runs the checks. `completion` gets link ID -> available, on the main thread,
    /// unless the check was cancelled.
    func run(channel: Channel, completion: @escaping ([UUID: Bool]) -> Void) {
        let links = channel.links
        os_log("Checking %d links of channel %{public}@…", links.count, channel.name)

        task = Task {
            let outcome = await withTaskGroup(of: (UUID, Bool).self) { group -> [UUID: Bool] in
                for link in links {
                    group.addTask { (link.id, await Self.isAvailable(link)) }
                }
                var outcome: [UUID: Bool] = [:]
                for await (id, available) in group {
                    outcome[id] = available
                    await MainActor.run {
                        guard self.checkingChannelID == channel.id else { return }
                        self.results[id] = available ? .available : .unavailable
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

    private static func isAvailable(_ link: StreamLink) async -> Bool {
        guard let stream = link.stream else { return false }
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
            return false
        }

        var available = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let (data, _) = try? await session.data(from: statURL),
               let stats = try? JSONDecoder().decode(StatResponse.self, from: data),
               let peers = stats.response?.peers, peers > 0 {
                available = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Stop the test stream so it doesn't keep downloading.
        if let commandURL = URL(string: streamSession.commandURL) {
            _ = try? await session.data(from: commandURL.appendingQuery("method", "stop"))
        }
        os_log("Link %{public}@ available: %d", String(stream.hash.prefix(7)), available)
        return available
    }
}
