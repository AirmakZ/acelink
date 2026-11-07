import Cocoa
import os
import SwiftUI

/// The part of the engine's session stats that tells whether a player is being fed.
private struct PlaybackStats: Decodable {
    let response: Stats?

    struct Stats: Decodable {
        let status: String?
        let streamStatus: Int?
        let downloaded: Int?

        enum CodingKeys: String, CodingKey {
            case status
            case streamStatus = "stream_status"
            case downloaded
        }
    }
}

/// A stream playing on the Mac.
private struct MacPlayer {
    let slot: Int
    let linkID: UUID?
    let hash: String
    let name: String
    let bundle: Bundle
    /// The player app instance, once it's running. Nil for browsers.
    var app: NSRunningApplication?
    /// The engine's session feeding this player.
    let session: EngineSession?
    /// Reads the stream's shared HLS session (see joinSharedSession) instead of its own.
    var shared = false
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var loading = LoadingIndicator()
    /// Streams playing on the Mac. More than one with "Play Alongside".
    private var players: [MacPlayer] = [] {
        didSet { updatePlayingStatus() }
    }
    private var engine: AceStreamEngine?
    private var channelsWindow: ChannelsWindowController?
    private let status = PlaybackStatus.shared
    private let checker = LinkChecker.shared
    private let tv = TVShare.shared
    private var tvWatchdog: Timer?
    /// Callbacks waiting for a shared engine start (see ensureEngine).
    private var engineWaiters: [(String?) -> Void] = []

    /// Bumped every time a stream is opened or stopped. Callbacks from an older
    /// attempt compare against it and bail out, so clicking another link (or Stop)
    /// while one is still loading cancels the previous one.
    private var generation = 0

    /// Only one Ace Link may run. Copies share the single engine container but each starts
    /// it with its own token, so each sees the other's engine as foreign and recreates it
    /// (every 30 s while sharing to the TV), killing every stream and check. A second copy
    /// (e.g. the Xcode build next to the installed one) brings the first one forward and quits.
    func applicationWillFinishLaunching(_: Notification) {
        guard let older = Self.olderRunningCopy() else { return }
        os_log("Ace Link is already running (pid %d); switching to it.", older.processIdentifier)
        guard let url = older.bundleURL else { exit(0) }
        olderCopyURL = url
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Opening the running copy sends it a reopen event, which shows its channels window.
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            // Give a stream link this copy was opened with time to arrive and be forwarded.
            // Not NSApp.terminate: applicationWillTerminate would stop the engine and the
            // players, which belong to the other copy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }

    /// Another running Ace Link that started before this one. The older one wins, so two
    /// copies launched at the same moment don't both quit.
    private static func olderRunningCopy() -> NSRunningApplication? {
        let me = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
            .first { other in
                switch (other.launchDate, me.launchDate) {
                case let (otherDate?, myDate?) where otherDate != myDate:
                    return otherDate < myDate
                default:
                    return other.processIdentifier < me.processIdentifier
                }
            }
    }

    /// Set when another copy is already running and this one is about to quit: nothing
    /// may start (menu bar item, TV server, engine) in the meantime.
    private var olderCopyURL: URL?
    private var isDuplicate: Bool { olderCopyURL != nil }

    func applicationDidFinishLaunching(_: Notification) {
        guard !isDuplicate else { return }

        // Who watches what: the relay's readers change without any event, so check often.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }

        // Real-time transfer rates of what plays on the Mac and the TV, shown in the list.
        TransferMonitor.shared.start(sessions: { [weak self] in
            guard let self = self else { return [:] }
            var sessions = self.tv.isEnabled ? self.tv.sessionStatURLs() : [:]
            for player in self.players {
                if let url = player.session?.statURL { sessions[player.hash.lowercased()] = url }
            }
            return sessions
        }, onGone: { [weak self] hash in
            self?.tv.forgetSession(hash: hash)
        })
        NSApp.mainMenu = AppMainMenu.build(target: self)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.menu = MainMenu(title: "Ace Link")

        if let statusItemButton = statusItem?.button {
            loading.statusItemButton = statusItemButton
            statusItemButton.image = NSImage(named: "StatusBarIcon")
            statusItemButton.imageScaling = .scaleProportionallyDown
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: OperationQueue.main,
            using: detectLaunchedBundleTerminated
        )

        showChannelsWindow(nil)

        if tv.isEnabled {
            setTVSharing(true)
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard !isDuplicate else { return false }
        showChannelsWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false // Keep running in the menu bar.
    }

    func application(_: NSApplication, open urls: [URL]) {
        if let olderCopyURL = olderCopyURL {
            // A stream link opened this copy; the one already running plays it.
            NSWorkspace.shared.open(
                urls, withApplicationAt: olderCopyURL, configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }
        if Process.runCommand("docker", "--version").terminationStatus != 0 {
            return
        }
        if let url = urls.first, let stream = ExtractStream.from(applicationURL: url) {
            openStream(stream)
        } else {
            NSAlert.error("Unrecognized stream format.")
        }
    }

    func applicationWillTerminate(_: Notification) {
        guard !isDuplicate else { return } // The engine belongs to the other copy.
        stopAceStreamServer()
        terminatePlayers()
    }

    // MARK: - Channels window

    @objc
    func showChannelsWindow(_: Any?) {
        if channelsWindow == nil {
            channelsWindow = ChannelsWindowController(actions: PlaybackActions(
                play: { [weak self] link in self?.play(link: link) },
                playAlongside: { [weak self] link in self?.play(link: link, alongside: true) },
                stopLink: { [weak self] in self?.stopPlaying(linkID: $0) },
                stopStream: { [weak self] in self?.stopPlaying(hash: $0) },
                playFromClipboard: { [weak self] in self?.playFromClipboard() },
                stop: { [weak self] in self?.stopPlayback() },
                checkAvailability: { [weak self] in self?.checkAvailability(channelID: $0) },
                checkLink: { [weak self] in self?.checkAvailability(channelID: $0, linkID: $1) },
                cancelCheck: { [weak self] in self?.cancelCheck() },
                setTVSharing: { [weak self] in self?.setTVSharing($0) }
            ))
        }
        channelsWindow?.show()
    }

    func play(link: StreamLink, alongside: Bool = false) {
        guard let stream = link.stream else {
            status.set(.failed("“\(link.name)” is not a valid AceStream link."))
            return
        }
        if alongside, players.contains(where: { $0.hash == stream.hash }) {
            // The engine sends a stream to one player only; a second one gets nothing.
            status.set(.failed("“\(link.name)” is already playing."))
            return
        }
        openStream(stream, linkID: link.id, displayName: link.name, alongside: alongside)
    }

    func playFromClipboard() {
        guard let clip = NSPasteboard.general.string(forType: .string),
              let stream = ExtractStream.from(unverifiedData: clip), !stream.hash.isEmpty
        else {
            status.set(.failed("No AceStream link found on the clipboard."))
            return
        }
        openStream(stream)
    }

    func stopPlayback() {
        checker.cancel()
        generation += 1
        loading.stop()
        terminatePlayers()
        if !tv.isEnabled {
            stopAceStreamServer()
        }
        status.activeLinkID = nil
        status.set(.idle)
    }

    /// Stops one stream playing on the Mac: closes its player and ends its engine session,
    /// so the engine stops downloading it. Other streams (and the TV) keep playing.
    func stopPlaying(linkID: UUID) {
        stopPlayers { $0.linkID == linkID }
    }

    /// Stops a stream playing on the Mac, from the Now Playing bar. A TV keeps playing.
    func stopPlaying(hash: String) {
        let hash = hash.lowercased()
        stopPlayers { $0.hash.lowercased() == hash }
    }

    private func stopPlayers(where matches: (MacPlayer) -> Bool) {
        let stopping = players.filter(matches)
        guard !stopping.isEmpty else { return }
        players.removeAll(where: matches)
        for player in stopping {
            os_log("Stop playing %{public}@", String(player.hash.prefix(7)))
            if !player.bundle.isBrowser { player.app?.terminate() }
            endSession(of: player)
        }
        guard players.isEmpty else { return }
        if !tv.isEnabled, !checker.isRunning {
            stopAceStreamServer()
        }
        if !status.isBusy {
            status.set(.idle)
        }
    }

    // MARK: - Share to TV

    @objc
    func toggleTVSharing(_: Any?) {
        setTVSharing(!tv.isEnabled)
    }

    func setTVSharing(_ enabled: Bool) {
        if enabled {
            if let error = tv.enable() {
                tv.set(.failed(error))
                return
            }
            keepEngineRunningForTV()
            tvWatchdog?.invalidate()
            // Restart the engine if it dies (e.g. Docker restarted) while sharing.
            tvWatchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.keepEngineRunningForTV()
            }
        } else {
            tvWatchdog?.invalidate()
            tvWatchdog = nil
            tv.disable()
            if players.isEmpty, !checker.isRunning, !status.isBusy {
                stopAceStreamServer()
            }
        }
    }

    private func keepEngineRunningForTV() {
        guard tv.isEnabled, engineWaiters.isEmpty else { return }
        if Process.runCommand("docker", "--version").terminationStatus != 0 {
            tv.set(.failed("Docker is not installed."))
            return
        }
        if tv.state != .on {
            tv.set(.starting("Starting AceStream engine…"))
        }
        ensureEngine { error in
            guard self.tv.isEnabled else { return }
            self.tv.set(error.map { .failed($0) } ?? .on)
        }
    }

    /// Makes sure an engine is running, reusing the current one if it responds.
    /// Concurrent callers share a single start.
    private func ensureEngine(_ done: @escaping (String?) -> Void) {
        engineWaiters.append(done)
        guard engineWaiters.count == 1 else { return }

        let token = engine?.token
        DispatchQueue.global().async {
            let alive = token.map(Self.engineResponds) ?? false
            DispatchQueue.main.async {
                if alive {
                    self.finishEngineWaiters(nil)
                } else {
                    self.bootEngine { self.finishEngineWaiters($0) }
                }
            }
        }
    }

    private func finishEngineWaiters(_ error: String?) {
        let waiters = engineWaiters
        engineWaiters = []
        waiters.forEach { $0(error) }
    }

    /// True when *our* engine answers: the page only loads with the token it was started with,
    /// so an engine replaced by something else (e.g. another Ace Link copy) is detected.
    private static func engineResponds(token: String) -> Bool {
        let url = AppConstants.Docker.baseURL.appendingPathComponent("/webui/app/\(token)/server")
        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(
            with: URLRequest(url: url, timeoutInterval: 3)
        ) { data, _, _ in
            ok = data.map { String(decoding: $0, as: UTF8.self).contains("access_token") } ?? false
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)
        return ok
    }

    /// Starts Docker, pulls the image and starts a fresh engine container.
    private func bootEngine(_ done: @escaping (String?) -> Void) {
        func progress(_ message: String) {
            if case .starting = tv.state { tv.set(.starting(message)) }
            if case .working = status.state { status.set(.working(message)) }
        }
        progress("Starting Docker…")
        DockerEngine().task { error in
            if let message = error?.errorDescription { return done(message) }
            progress("Preparing AceStream image (first run can take a while)…")
            DockerImage().task { error in
                if let message = error?.errorDescription { return done(message) }
                progress("Starting AceStream engine…")
                let launchedContainer = AceStreamEngine()
                launchedContainer.task { error in
                    if let message = error?.errorDescription { return done(message) }
                    self.engine = launchedContainer
                    done(nil)
                }
            }
        }
    }

    // MARK: - Availability check

    /// Checks every link of a channel, or only `linkID` when given.
    func checkAvailability(channelID: UUID, linkID: UUID? = nil) {
        guard var channel = ChannelStore.shared.channel(id: channelID),
              !checker.isRunning, !status.isBusy else { return }
        if let linkID = linkID {
            channel.links = channel.links.filter { $0.id == linkID }
        }
        guard !channel.links.isEmpty else { return }

        if Process.runCommand("docker", "--version").terminationStatus != 0 {
            fail("Docker is not installed. Install Docker Desktop from the menu bar icon.",
                 generation: generation)
            return
        }

        let macHashes = Set(players.map { $0.hash.lowercased() })
        let sharing = tv.isEnabled
        DispatchQueue.global().async {
            let tvHashes = sharing ? self.tv.activeStreamHashes() : []
            DispatchQueue.main.async {
                self.startCheck(
                    channel: channel, singleLink: linkID != nil, playing: macHashes.union(tvHashes)
                )
            }
        }
    }

    /// Streams playing on the Mac or the TV are left out: testing one opens another
    /// session for it, and the engine sends a stream to one session only.
    private func startCheck(channel: Channel, singleLink: Bool, playing: Set<String>) {
        guard !checker.isRunning, !status.isBusy else { return }
        var channel = channel
        let channelID = channel.id
        channel.links.removeAll { link in
            link.stream.map { playing.contains($0.hash.lowercased()) } ?? false
        }
        if channel.links.isEmpty {
            status.set(.failed(singleLink
                ? "This link is playing. Checking it now would interrupt it."
                : "All links of this channel are playing. Checking them would interrupt them."))
            return
        }
        if !playing.isEmpty {
            os_log("Leaving %d playing stream(s) out of the check.", playing.count)
        }

        checker.begin(channel: channel)

        // If a stream is playing, use its engine instead of restarting it.
        let reuseEngine = !players.isEmpty && engine != nil
        let prepareEngine: (@escaping (String?) -> Void) -> Void
        if tv.isEnabled {
            prepareEngine = ensureEngine // Never restart the engine while the TV may be using it.
        } else if reuseEngine {
            prepareEngine = { done in done(nil) }
        } else {
            prepareEngine = startEngineForCheck
        }

        prepareEngine { error in
            guard self.checker.checkingChannelID == channelID else { return } // Cancelled.
            if let error = error {
                self.checker.cancel()
                self.status.set(.failed(error))
                return
            }
            if !reuseEngine {
                let count = channel.links.count
                self.status.set(.working("Checking \(count) link\(count == 1 ? "" : "s")…"))
            }
            let maxConcurrent = playing.isEmpty ? Int.max : LinkChecker.concurrencyWhilePlaying
            self.checker.run(channel: channel, maxConcurrent: maxConcurrent) { outcome in
                let available = outcome.values.filter { $0.rank == 0 }.count
                os_log("Check done: %d of %d available.", available, outcome.count)
                // A single link keeps its place; sorting only makes sense for the whole channel.
                if !singleLink {
                    withAnimation {
                        ChannelStore.shared.sortLinks(in: channelID, by: outcome)
                    }
                }
                self.finishCheck()
            }
        }
    }

    func cancelCheck() {
        checker.cancel()
        finishCheck()
    }

    /// Stops the engine after a check, unless a stream is playing or loading.
    private func finishCheck() {
        guard players.isEmpty else {
            if case .working = status.state, status.activeLinkID == nil { status.dismiss() }
            return
        }
        if case .working = status.state, status.activeLinkID != nil { return }
        if !tv.isEnabled {
            stopAceStreamServer()
        }
        status.set(.idle)
    }

    private func startEngineForCheck(_ done: @escaping (String?) -> Void) {
        status.set(.working("Starting Docker…"))
        DockerEngine().task { error in
            guard self.checker.isRunning else { return }
            if let message = error?.errorDescription { return done(message) }

            self.status.set(.working("Preparing AceStream image (first run can take a while)…"))
            DockerImage().task { error in
                guard self.checker.isRunning else { return }
                if let message = error?.errorDescription { return done(message) }

                self.status.set(.working("Starting AceStream engine…"))
                let launchedContainer = AceStreamEngine()
                launchedContainer.task { error in
                    guard self.checker.isRunning else { return }
                    if let message = error?.errorDescription { return done(message) }
                    self.engine = launchedContainer
                    done(nil)
                }
            }
        }
    }

    // MARK: - Playback

    /// Opens a stream in the media player. Normally it replaces what's playing;
    /// with `alongside` it plays next to it, in another player window.
    func openStream(
        _ stream: StreamFile, linkID: UUID? = nil, displayName: String? = nil,
        alongside: Bool = false
    ) {
        if Process.runCommand("docker", "--version").terminationStatus != 0 {
            fail("Docker is not installed. Install Docker Desktop from the menu bar icon.",
                 generation: generation)
            return
        }

        // Alongside only makes sense when something is playing; otherwise just play.
        let alongside = alongside && !players.isEmpty && engine != nil
        if !tv.isEnabled, !alongside {
            checker.cancel() // Starting a stream restarts the engine, which would break a check.
        } else {
            checker.drop(hash: stream.hash) // Its test session would cut it as soon as it plays.
            checker.throttle(to: LinkChecker.concurrencyWhilePlaying)
        }
        generation += 1
        let generation = self.generation
        status.activeLinkID = linkID

        var stream = stream
        if alongside {
            let used = Set(players.map(\.slot))
            stream.slot = (0...).first { !used.contains($0) }!
        } else {
            terminatePlayers(keepingSessionOf: stream.hash)
        }
        os_log("Open stream: %{public}s=%s (slot %d)", stream.param, stream.hash, stream.slot)

        startAceStreamEngine(generation: generation, reuse: alongside) {
            os_log("Ace Stream engine ready.")
            let engine = self.engine!

            if stream.hash.isEmpty {
                // Just prepare the server, some websites launch acestream:// without args,
                // task communicate directly with the server.
                os_log("No stream hash, leaving the engine running…")
                self.loading.stop()
                self.status.set(.idle)
                return
            }

            func launch(_ bundle: Bundle, _ url: URL, _ stream: StreamFile, shared: Bool = false) {
                os_log(
                    "Launching %{public}@ with URL %s…",
                    bundle.debugDescription,
                    url.debugDescription
                )

                let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? stream.title
                let slot = stream.slot
                self.players.append(
                    MacPlayer(
                        slot: slot, linkID: linkID, hash: stream.hash, name: name,
                        bundle: bundle, session: stream.session, shared: shared
                    )
                )
                self.loading.stop()
                self.status.activeLinkID = nil
                self.status.set(.playing(self.status.nowPlaying ?? name))
                if let statURL = stream.session?.statURL, !bundle.isBrowser {
                    self.markSeenOncePlaying(stream.hash, slot: slot, statURL: statURL)
                }

                let config = NSWorkspace.OpenConfiguration()
                // A second stream needs its own player window: VLC would otherwise
                // replace the first stream with it.
                config.createsNewApplicationInstance = alongside && !bundle.isBrowser
                NSWorkspace.shared.open(
                    [url], withApplicationAt: bundle.bundleURL, configuration: config
                ) { app, error in
                    DispatchQueue.main.async {
                        guard let index = self.players.firstIndex(where: { $0.slot == slot })
                        else { return } // Stopped meanwhile.
                        if let error = error {
                            os_log("Cannot open player: %{public}@", error.localizedDescription)
                        }
                        if bundle.isBrowser { return }
                        // Without the app instance a closed player can't be recognized and
                        // would look like it's still playing. macOS may not return one, e.g.
                        // when the URL goes to a copy of the player that is still quitting.
                        let app = app ?? NSRunningApplication
                            .runningApplications(withBundleIdentifier: bundle.bundleIdentifier ?? "")
                            .filter { !$0.isTerminated }
                            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
                        os_log("Player opened: %{public}@ pid %d (slot %d)",
                               app?.bundleIdentifier ?? "nil", app?.processIdentifier ?? -1, slot)
                        self.players[index].app = app
                    }
                }
            }

            if self.tv.state == .on, let bundle = AppConfig.playerBundle, !bundle.isBrowser {
                self.joinSharedSession(
                    stream: stream, fallbackTitle: displayName, generation: generation
                ) { stream, url in
                    launch(bundle, url, stream, shared: true)
                }
                return
            }

            self.prepareStream(
                engine: engine, stream: stream, fallbackTitle: displayName, generation: generation
            ) { stream in
                self.launchStreamInEngine(
                    engine: engine, stream: stream, generation: generation
                ) { bundle, url in
                    launch(bundle, url, stream)
                }
            }
        }
    }

    /// Updates "last seen" once the engine is feeding the player video. Peers alone (what
    /// opening the player waits for) don't mean a link plays: it can have peers and no video.
    private func markSeenOncePlaying(_ hash: String, slot: Int, statURL: URL) {
        Task {
            var firstDownloaded: Int?
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let stillPlaying = await MainActor.run {
                    self.players.contains { $0.slot == slot && $0.hash == hash }
                }
                guard stillPlaying else { return }

                guard let (data, _) = try? await URLSession.shared.data(from: statURL),
                      let stats = try? JSONDecoder().decode(PlaybackStats.self, from: data)
                        .response else { continue }
                let downloaded = stats.downloaded ?? 0
                if firstDownloaded == nil { firstDownloaded = downloaded }
                // stream_status 1: the engine is sending the stream to a player (-1 once
                // another session has taken it over). And video keeps arriving.
                if stats.status == "dl", stats.streamStatus == 1,
                   downloaded - (firstDownloaded ?? downloaded) >= 1_048_576 {
                    os_log("Playing %{public}@ fine; updating last seen.", String(hash.prefix(7)))
                    await MainActor.run { ChannelStore.shared.markSeen(hash: hash) }
                    return
                }
            }
        }
    }

    /// While sharing to the TV, the Mac plays the same HLS session the TV uses for a stream
    /// (see TVShare.sessionPlayerID), so the Mac and the TV can watch the same channel: the
    /// engine sends a stream to one session only. Waits until the session has video, then
    /// hands the player the same address, which by then answers at once.
    private func joinSharedSession(
        stream: StreamFile,
        fallbackTitle: String?,
        generation: Int,
        callback: @escaping (StreamFile, URL) -> Void
    ) {
        os_log("Joining the shared session for %{public}@…", String(stream.hash.prefix(7)))
        status.set(.working("Waiting for video…"))

        let url = TVShare.localPlayURL(for: stream)
        // Up to the TV server's own give-up time (≈ 54 s of redirects), plus margin.
        let request = URLRequest(url: url, timeoutInterval: 70)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let ready = (response as? HTTPURLResponse)?.statusCode == 200
                && body.contains("#EXTINF")
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                guard ready else {
                    self.fail("No video arrived. The link may be offline.", generation: generation)
                    return
                }
                var stream = stream
                let title = fallbackTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Stream"
                stream.title = "\(title) [\(stream.hash.prefix(7))]"
                // The session's playlist listed video segments: the link plays. (Its stats
                // can't tell: an HLS session's stream_status stays -1 while it's read.)
                ChannelStore.shared.markSeen(hash: stream.hash)
                callback(stream, url)
            }
        }.resume()
    }

    /// Shows the error in the channels window (and as an alert if the window is closed).
    func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        loading.stop()
        status.activeLinkID = nil
        status.set(.failed(message))
        if channelsWindow?.window?.isVisible != true {
            NSAlert.error(message)
        }
    }

    func prepareStream(
        engine: AceStreamEngine,
        stream: StreamFile,
        fallbackTitle: String?,
        generation: Int,
        callback: @escaping (StreamFile) -> Void
    ) {
        os_log("Preparing stream…")
        status.set(.working("Loading stream…"))

        let aceStreamPlaylist = AceStreamPlaylist(aceStreamEngine: engine, stream: stream)
        aceStreamPlaylist.task { error in
            guard generation == self.generation else { return }
            if let message = error?.errorDescription {
                // The title is only a label; carry on without it.
                os_log("%{public}@ Continuing without title.", message)
            }

            os_log("Waiting for peers…")
            self.status.set(.working("Waiting for peers…"))
            stream.waitForPeers { result, session in
                guard generation == self.generation else { return }
                if let message = result?.errorDescription {
                    self.fail(message, generation: generation)
                    return
                }

                var stream = stream
                stream.session = session
                let title = aceStreamPlaylist.title
                    ?? fallbackTitle.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Stream"
                stream.title = "\(title) [\(stream.hash.prefix(7))]"
                stream.addToHistory()

                callback(stream)
            }
        }
    }

    func launchStreamInEngine(
        engine: AceStreamEngine,
        stream: StreamFile,
        generation: Int,
        callback: @escaping (Bundle, URL) -> Void
    ) {
        os_log("Starting server for opening acelink.m3u8 over http…")
        status.set(.working("Opening player…"))

        guard let bundle = AppConfig.playerBundle else {
            fail("Cannot get player. Choose one with “Change media player…” in the menu bar.",
                 generation: generation)
            return
        }

        if bundle.isBrowser {
            callback(bundle, stream.getURLForBundleType(bundle))
            return
        }

        PlaylistServer(engine: engine, stream: stream).task { error in
            guard generation == self.generation else { return }
            if let message = error?.errorDescription {
                self.fail(message, generation: generation)
                return
            }

            callback(bundle, stream.getURLForBundleType(bundle))
        }
    }

    func startAceStreamEngine(generation: Int, reuse: Bool = false, _ callback: @escaping () -> Void) {
        loading.start()

        if tv.isEnabled || reuse {
            // Share the running engine with the TV or the other streams instead of restarting it.
            status.set(.working("Starting AceStream engine…"))
            ensureEngine { error in
                guard generation == self.generation else { return }
                if let message = error {
                    self.fail(message, generation: generation)
                    return
                }
                callback()
            }
            return
        }

        os_log("Starting Docker…")
        status.set(.working("Starting Docker…"))
        DockerEngine().task { error in
            guard generation == self.generation else { return }
            if let message = error?.errorDescription {
                self.fail(message, generation: generation)
                return
            }

            os_log("Pulling Docker image…")
            self.status.set(.working("Preparing AceStream image (first run can take a while)…"))
            DockerImage().task { error in
                guard generation == self.generation else { return }
                if let message = error?.errorDescription {
                    self.fail(message, generation: generation)
                    return
                }

                os_log("Starting AceStream server…")
                self.status.set(.working("Starting AceStream engine…"))
                let launchedContainer = AceStreamEngine()
                launchedContainer.task { error in
                    guard generation == self.generation else { return }
                    if let message = error?.errorDescription {
                        self.fail(message, generation: generation)
                        return
                    }

                    self.engine = launchedContainer
                    callback()
                }
            }
        }
    }

    func detectLaunchedBundleTerminated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           players.contains(where: { $0.bundle.bundleIdentifier == app.bundleIdentifier }),
           !players.contains(where: { $0.app?.processIdentifier == app.processIdentifier }) {
            // A player app quit but none of ours matches it: worth knowing if one stays "playing".
            os_log("Player app quit (pid %d), but no stream had that pid: %{public}@",
                   app.processIdentifier,
                   players.map { "\($0.app?.processIdentifier ?? -1)" }.joined(separator: ","))
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
            let index = players.firstIndex(where: {
                $0.app?.processIdentifier == app.processIdentifier
            })
        else { return }

        os_log("Player %{public}@ closed by user.", app.bundleIdentifier ?? "?")
        endSession(of: players.remove(at: index))
        if !players.isEmpty || checker.isRunning {
            return // Other streams (or the check) still need the engine.
        }
        if !tv.isEnabled {
            stopAceStreamServer() // The TV would still need it.
        }
        if !status.isBusy {
            status.set(.idle)
        }
    }

    /// Closes the player windows Ace Link opened.
    /// Pass `keepingSessionOf` when the same stream is about to play again: it reuses
    /// the session (same player id and stream), so ending it would cut the new playback.
    func terminatePlayers(keepingSessionOf keptHash: String? = nil) {
        let running = players
        players = []
        for player in running {
            if player.hash != keptHash {
                endSession(of: player)
            }
            if player.bundle.isBrowser {
                // A browser may have other tabs open; leave it.
                continue
            }
            if let app = player.app {
                os_log("Terminate player: %{public}@", player.bundle.bundleIdentifier ?? "?")
                app.terminate()
            }
        }
    }

    /// Tells the engine to end the session that fed a Mac player, so it stops downloading
    /// the stream. Without it the engine keeps going until it drops the idle session, which
    /// matters while the engine stays up for the TV. A player's own session is separate
    /// from the TV's; a shared one is only ended when no other Mac player reads it and no
    /// TV asked for the stream, so the TV is never cut by this.
    private func endSession(of player: MacPlayer) {
        if player.shared {
            // Another Mac window or a TV may read the same session; only end it when unused.
            guard !players.contains(where: { $0.hash == player.hash }) else { return }
            tv.endSessionIfUnused(hash: player.hash.lowercased())
            return
        }
        guard let commandURL = player.session?.commandURL else { return }
        os_log("Ending engine session of %{public}@", String(player.hash.prefix(7)))
        URLSession.shared.dataTask(with: commandURL.appendingQuery("method", "stop")).resume()
    }

    /// Updates the status bar and the list highlights after streams start or stop.
    private func updatePlayingStatus() {
        refreshNowPlaying()
        status.playingLinkIDs = Set(players.compactMap(\.linkID))
        switch players.count {
        case 0: status.nowPlaying = nil
        case 1: status.nowPlaying = "\(players[0].name) — in \(players[0].bundle.name)"
        default: status.nowPlaying = players.map(\.name).joined(separator: " + ")
        }
        if case .playing = status.state {
            status.dismiss()
        }
    }

    /// Rebuilds what plays where, for the link rows and the Now Playing bar: the players
    /// Ace Link opened on this Mac and, while sharing, every device reading the relay.
    private func refreshNowPlaying() {
        var viewers: [String: [Viewer]] = [:]
        var names: [String: String] = [:]
        for player in players {
            let hash = player.hash.lowercased()
            viewers[hash, default: []].append(.thisMac(player: player.bundle.name))
            names[hash] = player.name
        }
        if tv.isEnabled {
            // This Mac reads the relay as 127.0.0.1, or by its own network address.
            let ownAddresses = Set(["127.0.0.1"] + [TVShare.localIPAddress()].compactMap { $0 })
            for (hash, addresses) in tv.viewers() {
                for address in addresses {
                    if !ownAddresses.contains(address) {
                        viewers[hash, default: []].append(.device(address: address))
                    } else if !(viewers[hash] ?? []).contains(where: {
                        if case .thisMac = $0 { return true } else { return false }
                    }) {
                        viewers[hash, default: []].append(.thisMac(player: nil)) // Another app.
                    }
                }
            }
        }

        let channels = ChannelStore.shared.channels
        let streams = viewers.map { hash, viewers -> ActiveStream in
            let match = channels.lazy.compactMap { channel in
                channel.links.first { $0.stream?.hash.lowercased() == hash }.map { (channel, $0) }
            }.first
            let linkName = match.map { $0.1.name.isEmpty ? "Untitled link" : $0.1.name }
            return ActiveStream(
                hash: hash,
                name: linkName ?? names[hash] ?? String(hash.prefix(7)),
                channelID: match?.0.id,
                channelName: match?.0.name,
                channelIcon: match?.0.icon,
                viewers: viewers
            )
        }
        NowPlaying.shared.set(streams.sorted {
            ($0.channelName ?? "~", $0.name, $0.hash) < ($1.channelName ?? "~", $1.name, $1.hash)
        })
    }

    func stopAceStreamServer() {
        os_log("Stopping AceStream server…")
        _ = Process.runCommand("docker", "kill", AppConstants.Docker.containerName)
    }
}
