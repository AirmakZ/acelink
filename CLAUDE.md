# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AceLinkUI is a macOS menu bar app (AppKit + SwiftUI, macOS 13+) that plays AceStream/magnet links in an external media player (VLC by default), with a Channels window (organize links, remote list, availability checks, "Play Alongside", "Share to TV"). The AceStream engine (`ghcr.io/airmakz/acelinkui:<AceStream version>`, linux/amd64 only) runs in a Linux VM on Apple silicon with macOS 26, otherwise in Docker.

It was renamed from Ace Link on 2026-11-10 and is its own project now. It builds on [Ace Link](https://github.com/blaise-io/acelink) by Blaise Kal (the menu bar app, engine pipeline and image) and [e-ayguade/acelink](https://github.com/e-ayguade/acelink) by Enric Ayguadé (the Channels window concept it was forked from). Both are MIT: keep their copyright in `LICENSE` and the Credits section of the README.

## Commands

- **Build (Xcode project):** `xcodebuild -scheme AceLinkUI build` (or the Xcode `BuildProject` tool)
- **Build without Xcode:** `scripts/build-app.sh` → `build/AceLinkUI.app`; `--install` also copies to `/Applications`. It compiles every `*.swift` under `AceLinkUI/` with `swiftc` directly, so it doesn't need new files added to the project. The Xcode project does not use synchronized groups, so new files must also be added to `project.pbxproj`.
- **Docker image:** `make docker` (builds from root `Dockerfile`, with `acestream.conf` and `player.html` copied in)
- **Release:** `make build` (stamps `VERSION` into Info.plist and archives), `make release` (DMG), `make tag`
- **Lint/format:** configs are in `AceLinkUI/.swiftlint.yml` and `AceLinkUI/.swiftformat` (max width 100). They aren't wired into the build; run `swiftlint` / `swiftformat` manually if installed.
- **Tests:** there is no test target.
- **Logs:** `os_log` output; filter Console.app with `Process: AceLinkUI`, or read the Xcode console. `nw_path_necp_check_for_updates Failed to copy updated result (22)` is harmless system noise.
- **Don't use Xcode's `RunCodeSnippet` here:** it launches a full copy of the app; with Share to TV on, that copy also starts its own engine. Test logic in a standalone `swiftc` script instead. If a copy is left running, `kill -9` it; a normal quit runs `applicationWillTerminate`, which would `docker kill` the engine.

The app version comes from the root `VERSION` file. The engine image is tagged with the AceStream version it contains instead: `ARG ACESTREAM_VERSION` in the `Dockerfile` and `AppConstants.Docker.engineVersion` must match, and bumping them means that image has to exist on ghcr.io (CI in `.github/workflows/docker.yml` pushes `latest` and `<ACESTREAM_VERSION>` on master; `make docker` builds it locally). The image also contains `player.html` and `acestream.conf`: if either changes without a new AceStream version, don't push over the same tag, because `DockerImage` only checks that the image exists, so anyone who already has it never gets the new one. Use a suffix instead (e.g. `3.2.11-1`) in both the image tag and `engineVersion`. `ACESTREAM_VERSION` also builds the download URL, so the suffix needs its own value (e.g. a second `ARG`) read by the Makefile and CI.

## Architecture

**Entry and orchestration:** `main.swift` first takes over Ace Link's data folder and `io.blaise.acelink` settings on first launch (`migrateFromAceLink`), then sets up `AppDelegate` by hand (no storyboard app delegate). Only one copy may run (`applicationWillFinishLaunching`): copies share the engine container but each has its own token, so they'd keep recreating each other's engine. A second copy brings the first forward, forwards any stream URL, and `exit(0)`s without its quit cleanup. `AppDelegate` is the central coordinator: it owns the status item, the Channels window, the engine, and the list of playing `MacPlayer`s. Menus and SwiftUI views call into it: menus through `#selector(AppDelegate.…)`, the Channels window through a `PlaybackActions` closure bundle passed to `ChannelsWindowController`.

**Service pipeline (`Services/`):** each startup step subclasses `Service`, a polling base class. `run()` kicks off the work on a background queue, then `check()`/`hasRunSuccesfully()` is polled every `checkEverySeconds` until `maxWait`, and the callback fires on the main thread with an optional `AppError`. Playback chains these steps: Docker running → `DockerImage` pull → `AceStreamEngine` (`docker run` the container, wait for its access token) → `AceStreamPlaylist` (gets the stream title) → `PlaylistServer` (writes an m3u8 inside the container and serves it with `python3 -m http.server` on port 6888, because QuickTime/Safari can't play a local-file m3u8) → open the playlist URL in the player. Docker is always driven through the `docker` CLI via `Process.runCommand`.

**Engine without Docker (`EngineRuntime`, `EngineHelper/`):** on Apple silicon with macOS 26 the engine runs in a Linux VM instead of Docker. `acelinkui-engine` (a SwiftPM package using Apple's Containerization framework, built by `scripts/build-engine-helper.sh` into `Contents/MacOS`; Xcode runs it as the "Build engine helper" phase) is a separate executable because the framework needs macOS 26 and the app supports 13. `acelinkui-engine prepare` downloads the Kata kernel, the vminit filesystem and the same `ghcr.io/airmakz/acelinkui` image (amd64, run through Rosetta) into `~/Library/Application Support/AceLinkUI/Engine`; `acelinkui-engine run` boots it, forwards 127.0.0.1:6878/6888 to the VM, shares `Engine/playlists` as `/acelink` (`PlaylistServer` just writes the file there), and stops the VM on SIGTERM or when AceLinkUI exits. The Docker services (`DockerEngine`, `DockerImage`, `AceStreamEngine`, `PlaylistServer`, `stopAceStreamServer`) branch on `EngineRuntime.usesVM`; everything that talks HTTP to the engine is unchanged. `defaults write io.github.airmakz.acelinkui UseDocker -bool YES` forces Docker. Logs: `Engine/helper.log`, `Engine/run/engine.log`, `Engine/run/boot.log`.

**Concurrency rules in AppDelegate:**
- `generation` is bumped on every open/stop. Async callbacks compare against it and bail out if it changed, which is how starting another stream or pressing Stop cancels an in-flight load.
- `ensureEngine` reuses a running engine if it responds (`engineResponds(token:)` checks that it is *our* container). Concurrent callers share one start through `engineWaiters`.
- The engine must not be restarted while TV sharing is on or another stream or a check is using it. Several code paths (`stopPlayback`, `finishCheck`, player-terminated handling) check `tv.isEnabled` and `players` before stopping it.

**Engine sessions (measured, not documented anywhere):** the engine keeps **one session per stream** and **one stream per player id** (`pid`): asking for a stream under a new `pid` cuts the old session, and asking for another stream under the same `pid` ends the previous one. Two clients *can* read one HLS session. The same `pid` + stream returns the same session, and `manifest.m3u8?…&format=json` returns that session's `stat_url`/`command_url`/`playback_url` without disturbing it. The engine never pauses or drops a session nobody reads: it keeps downloading. There's no API to list sessions or readers. In HLS sessions `stream_status` stays -1. `speed_down` is a slow average, so live rates come from deltas of `downloaded`/`uploaded` (`TransferMonitor`).

**Multiple streams:** each `StreamFile` has a `slot`. Without Share to TV, the slot gives it its own playlist file (`acelink-N.m3u8`) and engine `pid` (`acelink-mac-N`). The same hash can't play twice on the Mac. Each Mac player's `EngineSession` (stat/command URLs) is kept, and `endSession(of:)` sends `method=stop` when the player goes away (Stop, window closed, replaced). Otherwise the engine downloads forever.

**Share to TV (`TVShare`):** an `NWListener` on port 8765 serves `/acelink.m3u`. `/play/<id|infohash>/<hash>.m3u8` warms the stream up in the engine (`pid=acelink-<hash>`, one session per stream shared by everyone), answering with redirects to itself until it's ready (TV players time out on cold starts), then redirects to `/hls/<hash>/index.m3u8`. Each stream (`WarmUp`) keeps its own **segment history**: a refresher reads the engine playlist every 2 s, numbers new segments with AceLinkUI's own sequence, and caches their contents. Players get playlists built from that history (`playlist(of:hash:delay:)`, 60 s window) and segments at `/hls/<hash>/seg/<sequence>.ts`. So a playlist request never fails, and segments survive their session dying. **TV players give up for good on any 404 (playlist or segment) and never re-request `/play`.** The engine's segment paths are *not* unique across sessions (a restarted session numbers from 0 again), so never key anything by engine path. TVs already play ~25–35 s behind the newest segment (the engine starts each session with that much video, converted to segments at once, and players start from it), which is their real cushion against drops; a "safety buffer" setting that held back more was tried and removed (2026-11-07) because the extra delay wasn't predictable. Every read is recorded with the client's IP (127.0.0.1 or the Mac's own address is this Mac). A sweep every 10 s ends sessions unread for 30 s, and restarts stuck ones under the hood (`restart`: same URLs, numbering continues, `#EXT-X-DISCONTINUITY`). While sharing, the Mac's player also opens the `/play` URL (`joinSharedSession`), so the Mac and TVs watch the same channel. `LocalDeviceNames` maps IPs to Bonjour names. `NowPlaying` (built in `AppDelegate.refreshNowPlaying`) combines Mac players and relay readers for the rows and the status bar.

**Channels (`Channels/`):** shared `ObservableObject` singletons drive the SwiftUI views:
- `ChannelStore.shared`: channels/links, saved to `~/Library/Application Support/AceLinkUI/channels.json` on every change, custom icons in `…/icons/`
- `PlaybackStatus.shared`: status bar text and the loading/playing link highlights
- `LinkChecker.shared`: availability check that reads each stream like a player would and classifies it by measured throughput (`Availability`). It must never test a stream that's playing (its session would cut the player's): playing streams are left out, a stream that starts playing is dropped (`drop(hash:)`), and the check throttles to 3 at a time (`throttle(to:)`, `CheckState`) while anything plays. Results are saved per link (`lastResult`, `lastSeen`).
- `TVShare.shared`: see above; also prevents sleep and App Nap while sharing, and optionally hides links that were dead in their last check
- `TransferMonitor.shared` / `NowPlaying.shared` (in `PlaybackStatus.swift`): live rates and who watches what

Their `set(_:)` helpers hop to the main thread, so they're safe to call from service callbacks.

**Stream parsing:** `ExtractStream` turns user input (hash, `acestream://`, `magnet:`, app-open URLs) into a `StreamFile`. `StreamLink.stream` returns nil for invalid input.

**Ports** (`AppConstants.Docker`): engine 6878, playlist proxy 6888, TV playlist 8765. The container name is `acelinkui-engine` (the old `acelink--ace-stream-server` is removed before ours starts).

## Design

The UI should follow Apple's Human Interface Guidelines as closely as possible:
- Prefer native SwiftUI/AppKit controls, layouts and behaviors over custom ones (standard toolbars, sidebars, sheets, context menus, keyboard shortcuts).
- Use SF Symbols, system colors, semantic fonts (`.caption`, `.title2`…) and system materials instead of hard-coded styling.
- Adopt the current design system (Liquid Glass, scroll edge effects, e.g. `safeAreaBar`) when it's available, behind `if #available(macOS 26, *)`, and keep a sensible fallback for the macOS 13 deployment target.
- Check `DocumentationSearch` for the current recommended API before building custom UI.

## Notes

- The app is unsigned (ad-hoc codesigned) because Apple doesn't allow p2p apps.
- When changing engine flags, keep the `--tmpfs=/dev/disk/by-id` mount in `AceStreamEngine.run()`. Without it the engine fails with "Cannot get stream title".
