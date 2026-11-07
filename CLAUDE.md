# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ace Link is a macOS menu bar app (AppKit + SwiftUI, macOS 13+) that plays AceStream/magnet links in an external media player (VLC by default). The AceStream engine runs in a Docker container (`blaiseio/acelink:<VERSION>`, linux/amd64 only). This fork adds a Channels window (organize links, availability checks, "Play Alongside", "Share to TV").

## Commands

- **Build (Xcode project):** `xcodebuild -scheme 'Ace Link' build` (or the Xcode `BuildProject` tool)
- **Build without Xcode:** `scripts/build-app.sh` → `build/Ace Link.app`; `--install` also copies to `/Applications`. It compiles every `*.swift` under `Ace Link/` with `swiftc` directly, so it doesn't need new files added to the project. The Xcode project does not use synchronized groups, so new files must also be added to `project.pbxproj`.
- **Docker image:** `make docker` (builds from root `Dockerfile`, with `acestream.conf` and `player.html` copied in)
- **Release:** `make build` (stamps `VERSION` into README/Info.plist and archives), `make release` (DMG), `make tag`
- **Lint/format:** configs are in `Ace Link/.swiftlint.yml` and `Ace Link/.swiftformat` (max width 100). They aren't wired into the build; run `swiftlint` / `swiftformat` manually if installed.
- **Tests:** there is no test target.
- **Logs:** `os_log` output; filter Console.app with `Process: Ace Link`, or read the Xcode console. `nw_path_necp_check_for_updates Failed to copy updated result (22)` is harmless system noise.
- **Don't use Xcode's `RunCodeSnippet` here:** it launches a full copy of the app; with Share to TV on, that copy also starts its own engine. Test logic in a standalone `swiftc` script instead. If a copy is left running, `kill -9` it; a normal quit runs `applicationWillTerminate`, which would `docker kill` the engine.

The app version comes from the root `VERSION` file, and that also picks the Docker image tag (`AppConstants.Docker.image`), so bumping `VERSION` means a matching image has to exist on Docker Hub (CI in `.github/workflows/docker.yml` pushes `latest` on master and `<tag>` on release).

## Architecture

**Entry and orchestration:** `main.swift` sets up `AppDelegate` by hand (no storyboard app delegate). Only one copy may run (`applicationWillFinishLaunching`): copies share the engine container but each has its own token, so they'd keep recreating each other's engine. A second copy brings the first forward, forwards any stream URL, and `exit(0)`s without its quit cleanup. `AppDelegate` is the central coordinator: it owns the status item, the Channels window, the engine, and the list of playing `MacPlayer`s. Menus and SwiftUI views call into it: menus through `#selector(AppDelegate.…)`, the Channels window through a `PlaybackActions` closure bundle passed to `ChannelsWindowController`.

**Service pipeline (`Services/`):** each startup step subclasses `Service`, a polling base class. `run()` kicks off the work on a background queue, then `check()`/`hasRunSuccesfully()` is polled every `checkEverySeconds` until `maxWait`, and the callback fires on the main thread with an optional `AppError`. Playback chains these steps: Docker running → `DockerImage` pull → `AceStreamEngine` (`docker run` the container, wait for its access token) → `AceStreamPlaylist` (gets the stream title) → `PlaylistServer` (writes an m3u8 inside the container and serves it with `python3 -m http.server` on port 6888, because QuickTime/Safari can't play a local-file m3u8) → open the playlist URL in the player. Docker is always driven through the `docker` CLI via `Process.runCommand`.

**Concurrency rules in AppDelegate:**
- `generation` is bumped on every open/stop. Async callbacks compare against it and bail out if it changed, which is how starting another stream or pressing Stop cancels an in-flight load.
- `ensureEngine` reuses a running engine if it responds (`engineResponds(token:)` checks that it is *our* container). Concurrent callers share one start through `engineWaiters`.
- The engine must not be restarted while TV sharing is on or another stream or a check is using it. Several code paths (`stopPlayback`, `finishCheck`, player-terminated handling) check `tv.isEnabled` and `players` before stopping it.

**Engine sessions (measured, not documented anywhere):** the engine keeps **one session per stream** and **one stream per player id** (`pid`): asking for a stream under a new `pid` cuts the old session, and asking for another stream under the same `pid` ends the previous one. Two clients *can* read one HLS session. The same `pid` + stream returns the same session, and `manifest.m3u8?…&format=json` returns that session's `stat_url`/`command_url`/`playback_url` without disturbing it. The engine never pauses or drops a session nobody reads: it keeps downloading. There's no API to list sessions or readers. In HLS sessions `stream_status` stays -1. `speed_down` is a slow average, so live rates come from deltas of `downloaded`/`uploaded` (`TransferMonitor`).

**Multiple streams:** each `StreamFile` has a `slot`. Without Share to TV, the slot gives it its own playlist file (`acelink-N.m3u8`) and engine `pid` (`acelink-mac-N`). The same hash can't play twice on the Mac. Each Mac player's `EngineSession` (stat/command URLs) is kept, and `endSession(of:)` sends `method=stop` when the player goes away (Stop, window closed, replaced). Otherwise the engine downloads forever.

**Share to TV (`TVShare`):** an `NWListener` on port 8765 serves `/acelink.m3u`. `/play/<id|infohash>/<hash>.m3u8` warms the stream up in the engine (`pid=acelink-<hash>`, one session per stream shared by everyone), answering with redirects to itself until it's ready (TV players time out on cold starts). Then it redirects to `/hls/<hash>/index.m3u8`, the relay: Ace Link fetches the engine's playlist and segments and rewrites segment URLs to `/hls/<hash>/seg/ace/…`. While sharing, the Mac's player also opens the `/play` URL (`joinSharedSession`), so the Mac and TVs watch the same channel without cutting each other. Every read is recorded with the client's IP: 127.0.0.1 or the Mac's own address is this Mac. A sweep every 10 s ends sessions unread for 30 s. `LocalDeviceNames` maps IPs to Bonjour names (reverse DNS gives nothing on home networks). `NowPlaying` (built in `AppDelegate.refreshNowPlaying`) combines Mac players and relay readers for the rows and the status bar.

**Channels (`Channels/`):** shared `ObservableObject` singletons drive the SwiftUI views:
- `ChannelStore.shared`: channels/links, saved to `~/Library/Application Support/Ace Link/channels.json` on every change, custom icons in `…/icons/`
- `PlaybackStatus.shared`: status bar text and the loading/playing link highlights
- `LinkChecker.shared`: availability check that reads each stream like a player would and classifies it by measured throughput (`Availability`). It must never test a stream that's playing (its session would cut the player's): playing streams are left out, a stream that starts playing is dropped (`drop(hash:)`), and the check throttles to 3 at a time (`throttle(to:)`, `CheckState`) while anything plays. Results are saved per link (`lastResult`, `lastSeen`).
- `TVShare.shared`: see above; also prevents sleep and App Nap while sharing, and optionally hides links that were dead in their last check
- `TransferMonitor.shared` / `NowPlaying.shared` (in `PlaybackStatus.swift`): live rates and who watches what

Their `set(_:)` helpers hop to the main thread, so they're safe to call from service callbacks.

**Stream parsing:** `ExtractStream` turns user input (hash, `acestream://`, `magnet:`, app-open URLs) into a `StreamFile`. `StreamLink.stream` returns nil for invalid input.

**Ports** (`AppConstants.Docker`): engine 6878, playlist proxy 6888, TV playlist 8765. The container name is `acelink--ace-stream-server`.

## Design

The UI should follow Apple's Human Interface Guidelines as closely as possible:
- Prefer native SwiftUI/AppKit controls, layouts and behaviors over custom ones (standard toolbars, sidebars, sheets, context menus, keyboard shortcuts).
- Use SF Symbols, system colors, semantic fonts (`.caption`, `.title2`…) and system materials instead of hard-coded styling.
- Adopt the current design system (Liquid Glass, scroll edge effects, e.g. `safeAreaBar`) when it's available, behind `if #available(macOS 26, *)`, and keep a sensible fallback for the macOS 13 deployment target.
- Check `DocumentationSearch` for the current recommended API before building custom UI.

## Notes

- The app is unsigned (ad-hoc codesigned) because Apple doesn't allow p2p apps.
- When changing engine flags, keep the `--tmpfs=/dev/disk/by-id` mount in `AceStreamEngine.run()`. Without it the engine fails with "Cannot get stream title".
