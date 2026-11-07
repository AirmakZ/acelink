# Ace Link

Ace Link is a menu bar app that allows playing Ace Streams on macOS. 

Play an Ace Stream or Magnet in any media player by pasting the URL in the Ace Link menu, or open an acestream or magnet link in Ace Link.

## Channels (this fork)

Ace Link now opens a window where you can organize your streams:

- **Channels**: create a channel with a name and an icon (SF Symbol + color, an emoji, or your own image).
- **Links**: each channel holds several AceStream links (hash, `acestream://…` or `magnet:`). Adding a link pre-fills it from your clipboard, and warns if the link is already in this channel (not allowed) or in others.
- **Bulk add**: "Add in Bulk…" (⇧⌘L) takes many links at once, one per line, with an optional name on the same line (`HD Spanish acestream://…`). M3U playlists (`#EXTINF:-1,Name` + link) work too. Duplicates are skipped.
- **Check availability**: tests every link in a channel at the same time (or one link, from its context menu) by reading each one like a player would, and measures how fast the video arrives. Green = fast enough to watch (≥ 250 KB/s), orange = slow or stalled (likely to freeze), red = no peers, or peers but no video. The measured speed is shown under each link, and the channel's dot in the sidebar shows its best link. Working links move to the top, then slow ones, dead ones to the bottom, longest-dead last. A check takes about 15 seconds, or about 45 if a channel has dead links.
  - While something plays (on the Mac or a TV), a check tests 3 links at a time so it doesn't starve it, leaves out the links that are playing, and shows a clock on links waiting their turn.
  - The last result is remembered: after a restart each link shows it as a ring until it's checked again. "Last seen" shows when a link last worked, in a check or when it played.
- **Play**: click a link's ▶ button, or double-click the link, to start it. Ace Link starts Docker and the AceStream engine, then opens the stream in your media player (VLC by default).
- **Play alongside**: ⌥-click ▶ or ⌥-double-click a link (or right-click → Play Alongside) to watch it next to what's already playing, in a second player window. Playing a link normally replaces everything that's playing.
- **Now playing**: a playing link shows who watches it (This Mac, or a device on your network by the name it announces, e.g. "Samsung BU8000 43 TV") and its live download and upload rates and peers. The bar at the bottom of the window lists everything playing; with several streams, its ⌃ button opens a panel with each stream and Stop All. Hover a playing link's speaker (or right-click → Stop) to stop just that one.
- Right-click channels and links to edit, copy, or delete them. Drag to reorder.

- **Share to TV**: the TV button in the toolbar (or "Share to TV" in the menu bar menu) serves all your channels as a playlist at `http://<your-mac-ip>:8765/acelink.m3u`. Add it once in an IPTV app on your TV (tested with m3u-ip.tv on a Samsung TV). While it's on, the AceStream engine keeps running and the Mac doesn't sleep. The Mac and TVs can watch the same channel at once, and different channels too; Ace Link relays the video to the TV, so it knows what's being watched and stops downloading a channel about 30 seconds after nobody watches it. If a channel gets stuck or its session dies, Ace Link restarts it under the hood: the TV pauses briefly, repeats a few seconds and carries on. To show device names, macOS asks once for permission to find devices on your local network. Reserve your Mac's IP in your router so the address doesn't change. Links that were red in the last availability check are left out of the TV playlist (switch this off in the TV panel).

Channels are saved in `~/Library/Application Support/Ace Link/channels.json`. The menu bar icon still works as before, and closing the window keeps Ace Link running in the menu bar.

### Building without Xcode

```sh
scripts/build-app.sh            # builds build/Ace Link.app
scripts/build-app.sh --install  # also copies it to /Applications
```

Requires macOS 13 or later and the Xcode Command Line Tools.

## [Download for macOS](https://github.com/blaise-io/acelink/releases/download/2.1.0/Ace.Link.2.1.0.dmg)

 - Install using HomeBrew: `brew install --cask ace-link`
 - [Download an older version](https://github.com/blaise-io/acelink/releases)

Requires Docker and macOS High Sierra (10.13) or later.

<img width="660" height="400" alt="acelink-screenshot" src="https://github.com/user-attachments/assets/8d34c01f-a44f-4d79-8c66-cb6f27bc1fef" />
<img width="441" height="336" alt="image" src="https://github.com/user-attachments/assets/e3fa5228-8f9e-4dd6-9ffb-99c2bfd53d88" />


### Media players

Ace Link allows selecting your own media player. Ace Link does not transcode streams, so pick a player that supports popular audio and video codecs. VLC, IINA and MPV are free and open source media players that are able to play nearly anything. QuickTime and web browsers will play most streams, but not all. 

### Signing

Ace Link is an unsigned app because Apple does not allow p2p related applications. If your version of macOS does not allow opening unsigned applications, [follow these instructions to bypass this restriction](https://apple.stackexchange.com/a/240560).

### Ace Stream server only

If you just want to run the AceStream engine, you can do so without Ace Link:

```sh
docker run --platform=linux/amd64 --rm -p 6878:6878 blaiseio/acelink
# now open http://<network ip>:6878/ace/getstream?id=<acestream id>
# or http://<network ip>:6878/ace/getstream?infohash=<magnet uri> in a player
```

If you want to use a custom acestream.conf: 
```
docker run --platform=linux/amd64 --rm -p 6878:6878 -v "$(pwd)/acestream.conf:/opt/acestream/acestream.conf" blaiseio/acelink
```

### View Ace Link logs

1. Open Console.app
2. In the Console.app search field, type `Process: Ace Link`
3. Click on *Start* or *Start streaming*
4. Launch Ace Link and perform an action you want to debug
5. It should now start populating Console.app with debug information
