import Foundation

/// What the app is doing right now, shown at the bottom of the channels window.
final class PlaybackStatus: ObservableObject {
    static let shared = PlaybackStatus()

    enum State: Equatable {
        case idle
        case working(String)
        case playing(String)
        case failed(String)
    }

    @Published var state: State = .idle {
        didSet { onChange?() }
    }
    /// The link that is loading, so the list can show a spinner on it.
    @Published var activeLinkID: UUID? {
        didSet { onChange?() }
    }
    /// Called on the main thread after `state` or `activeLinkID` changes.
    var onChange: (() -> Void)?
    /// Links playing on the Mac right now (more than one with "Play Alongside").
    @Published var playingLinkIDs: Set<UUID> = []
    /// What the status bar shows when nothing else is going on.
    var nowPlaying: String?

    /// Clears an error and goes back to showing what's playing.
    func dismiss() {
        set(nowPlaying.map { .playing($0) } ?? .idle)
    }

    var isBusy: Bool {
        if case .working = state { return true }
        return false
    }

    func set(_ state: State) {
        if Thread.isMainThread {
            self.state = state
        } else {
            DispatchQueue.main.async { self.state = state }
        }
    }
}

/// How fast a stream is moving right now, per the engine's session stats.
struct TransferRate: Equatable {
    /// Downloaded from peers, KB/s.
    let downKBps: Int
    /// Uploaded to peers, KB/s.
    let upKBps: Int
    let peers: Int
}

/// Polls the engine's stats for every stream playing (on the Mac or the TV) and publishes
/// its real-time transfer rates. The engine's own `speed_down` is a slow average that
/// still carries the start-up burst, so rates come from how much `downloaded` and
/// `uploaded` grow between readings instead.
final class TransferMonitor: ObservableObject {
    static let shared = TransferMonitor()

    /// By lowercased stream hash.
    @Published private(set) var rates: [String: TransferRate] = [:]
    /// The last live rate of each stream, kept after it stops playing.
    @Published private(set) var lastRates: [String: TransferRate] = [:]

    private static let interval: TimeInterval = 2
    /// Readings averaged over, so the figures don't jump with every packet (≈ 6 s).
    private static let window = 4

    private struct Reading {
        let downloaded: Int
        let uploaded: Int
        let at: Date
    }

    private var readings: [String: [Reading]] = [:]
    private var timer: Timer?
    private var sessions: () -> [String: URL] = { [:] }
    private var onGone: (String, URL) -> Void = { _, _ in }

    /// Starts polling. `sessions` returns hash -> stats URL of what is playing now;
    /// `onGone` is told about streams whose session (stats URL) the engine has ended.
    func start(sessions: @escaping () -> [String: URL], onGone: @escaping (String, URL) -> Void) {
        self.sessions = sessions
        self.onGone = onGone
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let current = sessions()
        // Forget streams that stopped playing.
        readings = readings.filter { current[$0.key] != nil }
        if rates.keys.contains(where: { current[$0] == nil }) {
            rates = rates.filter { current[$0.key] != nil }
        }
        for (hash, url) in current {
            URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 3)) { data, _, _ in
                let stats = data.flatMap { try? JSONDecoder().decode(SessionStats.self, from: $0) }?
                    .response
                DispatchQueue.main.async { self.record(stats, hash: hash, url: url) }
            }.resume()
        }
    }

    private func record(_ stats: SessionStats.Stats?, hash: String, url: URL) {
        guard let stats = stats, let downloaded = stats.downloaded else {
            // The session is gone (e.g. the TV left it): no rate to show.
            readings[hash] = nil
            rates[hash] = nil
            onGone(hash, url)
            return
        }
        var list = readings[hash] ?? []
        list.append(Reading(downloaded: downloaded, uploaded: stats.uploaded ?? 0, at: Date()))
        list = Array(list.suffix(Self.window))
        readings[hash] = list
        guard let first = list.first, let last = list.last, last.at > first.at else { return }
        let seconds = last.at.timeIntervalSince(first.at)
        let rate = TransferRate(
            downKBps: max(0, Int(Double(last.downloaded - first.downloaded) / 1024 / seconds)),
            upKBps: max(0, Int(Double(last.uploaded - first.uploaded) / 1024 / seconds)),
            peers: stats.peers ?? 0
        )
        if rates[hash] != rate {
            rates[hash] = rate
            lastRates[hash] = rate
        }
    }

    /// Drops the last live rate of a stream, e.g. because a newer check measured it.
    func forgetLastRate(hash: String) {
        lastRates[hash.lowercased()] = nil
    }
}

private struct SessionStats: Decodable {
    let response: Stats?

    struct Stats: Decodable {
        let downloaded: Int?
        let uploaded: Int?
        let peers: Int?
    }
}

/// Someone watching a stream: this Mac (in the player AceLinkUI opened, if it did) or
/// another device on the network, known by its IP address.
enum Viewer: Hashable {
    case thisMac(player: String?)
    case device(address: String)
}

/// A stream being watched somewhere, for the link rows and the Now Playing bar.
struct ActiveStream: Identifiable, Equatable {
    /// Lowercased stream hash.
    let hash: String
    let name: String
    let channelID: UUID?
    let channelName: String?
    let channelIcon: ChannelIcon?
    let viewers: [Viewer]
    /// What's happening while it connects ("Waiting for peers…", "Connecting… 8 s"); nil
    /// once it plays.
    var connecting: String? = nil
    /// Being opened on this Mac right now, so the opening can be cancelled.
    var openingOnMac = false

    var id: String { hash }

    /// Plays in a player AceLinkUI opened on this Mac, so AceLinkUI can stop it. A TV can
    /// only be stopped on the TV.
    var playsOnMac: Bool {
        viewers.contains { viewer in
            if case .thisMac(player: .some) = viewer { return true }
            return false
        }
    }
}

/// Every stream being watched right now, on this Mac or on other devices.
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published private(set) var streams: [ActiveStream] = []

    func set(_ streams: [ActiveStream]) {
        if streams != self.streams { self.streams = streams }
    }

    func stream(hash: String) -> ActiveStream? {
        let hash = hash.lowercased()
        return streams.first { $0.hash == hash }
    }
}
