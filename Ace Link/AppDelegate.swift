import Cocoa
import os
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var loading = LoadingIndicator()
    private var launchedBundle: Bundle?
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

    func applicationDidFinishLaunching(_: Notification) {
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
        showChannelsWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false // Keep running in the menu bar.
    }

    func application(_: NSApplication, open urls: [URL]) {
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
        stopAceStreamServer()
        terminateLaunchedBundle()
    }

    // MARK: - Channels window

    @objc
    func showChannelsWindow(_: Any?) {
        if channelsWindow == nil {
            channelsWindow = ChannelsWindowController(actions: PlaybackActions(
                play: { [weak self] link in self?.play(link: link) },
                playFromClipboard: { [weak self] in self?.playFromClipboard() },
                stop: { [weak self] in self?.stopPlayback() },
                checkAvailability: { [weak self] in self?.checkAvailability(channelID: $0) },
                cancelCheck: { [weak self] in self?.cancelCheck() },
                setTVSharing: { [weak self] in self?.setTVSharing($0) }
            ))
        }
        channelsWindow?.show()
    }

    func play(link: StreamLink) {
        guard let stream = link.stream else {
            status.set(.failed("“\(link.name)” is not a valid AceStream link."))
            return
        }
        openStream(stream, linkID: link.id, displayName: link.name)
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
        terminateLaunchedBundle()
        if !tv.isEnabled {
            stopAceStreamServer()
        }
        status.activeLinkID = nil
        status.set(.idle)
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
            if launchedBundle == nil, !checker.isRunning, !status.isBusy {
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

    func checkAvailability(channelID: UUID) {
        guard let channel = ChannelStore.shared.channel(id: channelID), !channel.links.isEmpty,
              !checker.isRunning, !status.isBusy else { return }

        if Process.runCommand("docker", "--version").terminationStatus != 0 {
            fail("Docker is not installed. Install Docker Desktop from the menu bar icon.",
                 generation: generation)
            return
        }

        checker.begin(channel: channel)

        // If a stream is playing, use its engine instead of restarting it.
        let reuseEngine = launchedBundle != nil && engine != nil
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
                self.status.set(.working("Checking \(channel.links.count) links…"))
            }
            self.checker.run(channel: channel) { outcome in
                let available = outcome.values.filter { $0 }.count
                os_log("Check done: %d of %d available.", available, outcome.count)
                withAnimation {
                    ChannelStore.shared.sortLinks(in: channelID, by: outcome)
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
        guard launchedBundle == nil else { return }
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

    func openStream(_ stream: StreamFile, linkID: UUID? = nil, displayName: String? = nil) {
        if Process.runCommand("docker", "--version").terminationStatus != 0 {
            fail("Docker is not installed. Install Docker Desktop from the menu bar icon.",
                 generation: generation)
            return
        }

        if !tv.isEnabled {
            checker.cancel() // Starting a stream restarts the engine, which would break a check.
        }
        generation += 1
        let generation = self.generation
        status.activeLinkID = linkID

        terminateLaunchedBundle()
        os_log("Open stream: %{public}s=%s", stream.param, stream.hash)

        startAceStreamEngine(generation: generation) {
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

            self.prepareStream(
                engine: engine, stream: stream, fallbackTitle: displayName, generation: generation
            ) { stream in
                self.launchStreamInEngine(
                    engine: engine, stream: stream, generation: generation
                ) { bundle, url in
                    os_log(
                        "Launching %{public}@ with URL %s…",
                        bundle.debugDescription,
                        url.debugDescription
                    )

                    NSWorkspace.shared.open(
                        [url], withAppBundleIdentifier: bundle.bundleIdentifier,
                        options: [],
                        additionalEventParamDescriptor: nil,
                        launchIdentifiers: nil
                    )

                    self.launchedBundle = bundle
                    self.loading.stop()
                    let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? stream.title
                    self.status.set(.playing("\(name) — in \(bundle.name)"))
                }
            }
        }
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
            stream.waitForPeers { result in
                guard generation == self.generation else { return }
                if let message = result?.errorDescription {
                    self.fail(message, generation: generation)
                    return
                }

                var stream = stream
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

    func startAceStreamEngine(generation: Int, _ callback: @escaping () -> Void) {
        loading.start()

        if tv.isEnabled {
            // Share the running engine with the TV instead of restarting it.
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
        guard let launchedBundle = launchedBundle else {
            return
        }

        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey],
           let terminatedBundleIdentifier = (app as? NSRunningApplication)?.bundleIdentifier,
           terminatedBundleIdentifier == launchedBundle.bundleIdentifier {
            os_log("Bundle %{public}@ terminated by user.", terminatedBundleIdentifier)
            self.launchedBundle = nil
            status.activeLinkID = nil
            if checker.isRunning {
                return // The check still needs the engine; it stops it when done.
            }
            if tv.isEnabled {
                status.set(.idle)
                return // The TV still needs the engine.
            }
            stopAceStreamServer()
            status.set(.idle)
        }
    }

    func terminateLaunchedBundle() {
        guard let launchedBundle = launchedBundle else {
            return
        }
        if launchedBundle.isBrowser {
            os_log("Launched bundle is browser which may have other tabs open, not terminating.")
            self.launchedBundle = nil
            return
        }

        for runningApplication in NSWorkspace.shared.runningApplications
            where runningApplication.bundleIdentifier == launchedBundle.bundleIdentifier {
            os_log("Terminate launched bundle: %{public}@", launchedBundle)
            runningApplication.terminate()
            self.launchedBundle = nil
        }
    }

    func stopAceStreamServer() {
        os_log("Stopping AceStream server…")
        _ = Process.runCommand("docker", "kill", AppConstants.Docker.containerName)
    }
}
