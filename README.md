> [!WARNING]
> Due to time constraints, I will not review issues or pull requests unless core functionality is broken for most users. I am open to transferring ownership of this project to contributors who have selflessly helped improving this project in 2025 or before. You are also welcome to fork the project. If a fork gains traction within the community, I will archive this project and link to the fork.

# Ace Link

Ace Link is a menu bar app that allows playing Ace Streams on macOS. 

Play an Ace Stream or Magnet in any media player by pasting the URL in the Ace Link menu, or open an acestream or magnet link in Ace Link.

## Channels (this fork)

Ace Link now opens a window where you can organize your streams:

- **Channels**: create a channel with a name and an icon (SF Symbol + color, an emoji, or your own image).
- **Links**: each channel holds several AceStream links (hash, `acestream://…` or `magnet:`). Adding a link pre-fills it from your clipboard.
- **Bulk add**: "Add in Bulk…" (⇧⌘L) takes many links at once, one per line, with an optional name on the same line (`HD Spanish acestream://…`). M3U playlists (`#EXTINF:-1,Name` + link) work too. Duplicates are skipped.
- **Check availability**: tests every link in a channel at the same time and shows a green (peers found) or red (no peers) dot next to each. Working links move to the top, dead ones to the bottom. Links that work report back in a few seconds; dead ones are marked after 45 seconds. If a stream is playing, the check uses its engine without interrupting it.
- **Play**: click a link to start it. Ace Link starts Docker and the AceStream engine, then opens the stream in your media player (VLC by default). Progress is shown at the bottom of the window, with a Stop button.
- Right-click channels and links to edit, copy, or delete them. Drag to reorder.

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

<img src="acelink.png" width="350" alt="Ace Link" />

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
