import SwiftUI

/// The link being added or edited, together with the channel it belongs to.
struct LinkEditTarget: Identifiable {
    let channelID: UUID
    var link: StreamLink
    let isNew: Bool
    var id: UUID { link.id }
}

struct PlaybackActions {
    var play: (StreamLink) -> Void
    var playAlongside: (StreamLink) -> Void
    /// Stops one link playing on the Mac, leaving the others playing.
    var stopLink: (UUID) -> Void
    /// Stops a stream playing on the Mac by its hash, from the Now Playing bar.
    var stopStream: (String) -> Void
    var playFromClipboard: () -> Void
    var stop: () -> Void
    var checkAvailability: (UUID) -> Void
    /// Checks a single link: channel ID, link ID.
    var checkLink: (UUID, UUID) -> Void
    var cancelCheck: () -> Void
    var setTVSharing: (Bool) -> Void
}

/// View state for ChannelsView. (An ObservableObject instead of @State so the app
/// also builds with the Command Line Tools, which lack the SwiftUI macro plugin.)
final class ChannelsUIState: ObservableObject {
    @Published var selection: UUID?
    @Published var editingChannel: Channel?
    @Published var editingLink: LinkEditTarget?
    @Published var bulkAdd: BulkAddTarget?
    @Published var channelPendingDelete: Channel?
    @Published var showTVPanel = false
}

struct ChannelsView: View {
    @ObservedObject var store: ChannelStore
    @ObservedObject var status: PlaybackStatus
    @ObservedObject var checker = LinkChecker.shared
    @ObservedObject var tv = TVShare.shared
    let actions: PlaybackActions

    @StateObject private var ui = ChannelsUIState()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                if let channel = store.channel(id: ui.selection) {
                    ChannelDetailView(
                        channel: channel,
                        store: store,
                        status: status,
                        checker: checker,
                        actions: actions,
                        onPlay: actions.play,
                        onEditChannel: { ui.editingChannel = channel },
                        onEditLink: { ui.editingLink = $0 },
                        onBulkAdd: { ui.bulkAdd = BulkAddTarget(id: channel.id) }
                    )
                } else {
                    emptyDetail
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(
                    status: status,
                    onStopAll: actions.stop,
                    onStopStream: actions.stopStream,
                    onSelectChannel: { ui.selection = $0 }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ui.showTVPanel.toggle()
                } label: {
                    Label("Share to TV", systemImage: tv.isEnabled ? "tv.fill" : "tv")
                        .foregroundColor(tvColor)
                }
                .help("Watch your channels on a TV")
                .popover(isPresented: $ui.showTVPanel, arrowEdge: .bottom) {
                    TVSharePanel(tv: tv, onToggle: actions.setTVSharing)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: actions.playFromClipboard) {
                    Label("Play from Clipboard", systemImage: "doc.on.clipboard")
                }
                .help("Play the AceStream link currently on your clipboard")
            }
        }
        .sheet(item: $ui.editingChannel) { channel in
            ChannelEditor(
                channel: channel,
                isNew: store.channel(id: channel.id) == nil,
                onSave: { saved in
                    store.upsert(saved)
                    ui.selection = saved.id
                    ui.editingChannel = nil
                },
                onCancel: { ui.editingChannel = nil }
            )
        }
        .sheet(item: $ui.editingLink) { target in
            LinkEditor(
                link: target.link,
                isNew: target.isNew,
                channelID: target.channelID,
                channels: store.channels,
                onSave: { saved in
                    store.upsert(link: saved, in: target.channelID)
                    ui.editingLink = nil
                },
                onCancel: { ui.editingLink = nil }
            )
        }
        .sheet(item: $ui.bulkAdd) { target in
            BulkLinkEditor(
                existingLinks: store.channel(id: target.id)?.links ?? [],
                onAdd: { links in
                    store.add(links: links, to: target.id)
                    ui.bulkAdd = nil
                },
                onCancel: { ui.bulkAdd = nil }
            )
        }
        .confirmationDialog(
            "Delete \"\(ui.channelPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { ui.channelPendingDelete != nil },
                set: { if !$0 { ui.channelPendingDelete = nil } }
            ),
            presenting: ui.channelPendingDelete
        ) { channel in
            Button("Delete Channel", role: .destructive) {
                if ui.selection == channel.id { ui.selection = nil }
                store.delete(channelID: channel.id)
            }
        } message: { channel in
            Text("The channel and its \(channel.links.count) link(s) will be removed.")
        }
        .onAppear {
            if ui.selection == nil { ui.selection = store.channels.first?.id }
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private var tvColor: Color {
        switch tv.state {
        case .on: return .green
        case .failed: return .orange
        default: return .primary
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if #available(macOS 26, *) {
            // Rows scroll under the bar with the same blurred edge as the toolbar.
            // No divider here: the bar is as tall as the status bar's divider plus its row.
            channelList.safeAreaBar(edge: .bottom) {
                newChannelBar.frame(height: BottomBar.rowHeight + BottomBar.dividerHeight)
            }
        } else {
            // No scroll edge effect: stack them so rows never scroll under the bar.
            VStack(spacing: 0) {
                channelList
                Divider()
                newChannelBar.frame(height: BottomBar.rowHeight)
            }
        }
    }

    private var newChannelBar: some View {
        HStack {
            Button {
                ui.editingChannel = Channel(name: "")
            } label: {
                Label("New Channel", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 10)
    }

    private var channelList: some View {
        List(selection: $ui.selection) {
            ForEach(store.channels) { channel in
                HStack(spacing: 10) {
                    ChannelIconView(icon: channel.icon, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(channel.name).lineLimit(1)
                        Text("\(channel.links.count) link\(channel.links.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 4)
                    AvailabilityDot(
                        availability: checker.bestResult(for: channel),
                        previous: checker.bestPreviousResult(for: channel)
                    )
                }
                .padding(.vertical, 3)
                .tag(channel.id)
                .contextMenu {
                    Button("Edit Channel…") { ui.editingChannel = channel }
                    Button("Add Link…") {
                        ui.editingLink = LinkEditTarget(
                            channelID: channel.id, link: LinkEditor.draftFromClipboard(), isNew: true
                        )
                    }
                    Button("Add Links in Bulk…") { ui.bulkAdd = BulkAddTarget(id: channel.id) }
                    Button("Check Availability") { actions.checkAvailability(channel.id) }
                        .disabled(channel.links.isEmpty || checker.isRunning || status.isBusy)
                    Divider()
                    Button("Delete Channel…") { ui.channelPendingDelete = channel }
                }
            }
            .onMove(perform: store.moveChannels)
        }
        .onDeleteCommand {
            if let channel = store.channel(id: ui.selection) { ui.channelPendingDelete = channel }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(store.channels.isEmpty ? "No channels yet" : "Select a channel")
                .font(.title2)
            if store.channels.isEmpty {
                Text("Create a channel, then add one or more AceStream links to it.")
                    .foregroundColor(.secondary)
                Button("New Channel") { ui.editingChannel = Channel(name: "") }
                    .controlSize(.large)
                    .keyboardShortcut("n")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Channel detail

struct ChannelDetailView: View {
    let channel: Channel
    @ObservedObject var store: ChannelStore
    @ObservedObject var status: PlaybackStatus
    @ObservedObject var checker: LinkChecker
    @ObservedObject var transfers = TransferMonitor.shared
    @ObservedObject var nowPlaying = NowPlaying.shared
    let actions: PlaybackActions
    let onPlay: (StreamLink) -> Void
    let onEditChannel: () -> Void
    let onEditLink: (LinkEditTarget) -> Void
    let onBulkAdd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if channel.links.isEmpty {
                VStack(spacing: 10) {
                    Text("No links in this channel").font(.title3)
                    Text("Add an AceStream link (hash, acestream:// or magnet:).")
                        .foregroundColor(.secondary)
                    HStack {
                        Button("Add Link", action: addLink)
                        Button("Add in Bulk…", action: onBulkAdd)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(channel.links) { link in
                        LinkRow(
                            link: link,
                            isLoading: status.activeLinkID == link.id && status.isBusy,
                            isPlaying: status.playingLinkIDs.contains(link.id),
                            availability: checker.results[link.id],
                            rate: link.stream.flatMap { transfers.rates[$0.hash.lowercased()] },
                            viewers: link.stream.flatMap { nowPlaying.stream(hash: $0.hash) }?.viewers ?? [],
                            onStop: { actions.stopLink(link.id) },
                            onPlay: {
                                if NSEvent.modifierFlags.contains(.option) {
                                    actions.playAlongside(link)
                                } else {
                                    onPlay(link)
                                }
                            }
                        )
                        // A soft green behind every link being watched, on this Mac or on
                        // another device, so playing links stand out at a glance.
                        .listRowBackground(
                            link.stream.flatMap { nowPlaying.stream(hash: $0.hash) } == nil ? nil
                                : RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.green.opacity(0.14))
                                    .padding(.horizontal, 4)
                        )
                        .contextMenu {
                            if status.playingLinkIDs.contains(link.id) {
                                Button("Stop") { actions.stopLink(link.id) }
                            }
                            Button("Play") { onPlay(link) }
                            Button("Play Alongside") { actions.playAlongside(link) }
                                .disabled(status.playingLinkIDs.isEmpty || status.isBusy)
                            Button("Check Availability") { actions.checkLink(channel.id, link.id) }
                                .disabled(link.stream == nil || checker.isRunning || status.isBusy)
                            Divider()
                            Button("Edit Link…") {
                                onEditLink(
                                    LinkEditTarget(channelID: channel.id, link: link, isNew: false)
                                )
                            }
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link.url, forType: .string)
                            }
                            Divider()
                            Button("Delete Link") {
                                store.delete(linkID: link.id, in: channel.id)
                            }
                        }
                    }
                    .onMove { store.moveLinks(in: channel.id, from: $0, to: $1) }
                    .onDelete { offsets in
                        for index in offsets {
                            store.delete(linkID: channel.links[index].id, in: channel.id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(channel.name)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ChannelIconView(icon: channel.icon, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.title2).bold()
                Text("\(channel.links.count) link\(channel.links.count == 1 ? "" : "s")")
                    .foregroundColor(.secondary)
            }
            Spacer()
            checkButton
            Button("Edit", action: onEditChannel)
            Button("Add in Bulk…", action: onBulkAdd)
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(action: addLink) {
                Label("Add Link", systemImage: "plus")
            }
            .keyboardShortcut("l")
        }
        .padding(16)
    }

    @ViewBuilder
    private var checkButton: some View {
        if checker.checkingChannelID == channel.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundColor(.secondary)
                Button("Cancel", action: actions.cancelCheck)
            }
        } else {
            Button {
                actions.checkAvailability(channel.id)
            } label: {
                Label("Check Availability", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(channel.links.isEmpty || checker.isRunning || status.isBusy)
            .help("Test every link at the same time. Working links move to the top.")
        }
    }

    private func addLink() {
        let draft = LinkEditor.draftFromClipboard(defaultName: "Link \(channel.links.count + 1)")
        onEditLink(LinkEditTarget(channelID: channel.id, link: draft, isNew: true))
    }
}

struct SpeedLabel: View {
    let availability: Availability?

    private var label: (text: String, color: Color)? {
        switch availability {
        case let .available(kbps)?: return ("\(kbps) KB/s", .green)
        case let .slow(kbps)?: return (kbps == 0 ? "stalled" : "\(kbps) KB/s · slow", .orange)
        case .noVideo?: return ("no video", .red)
        case .unavailable?: return ("no peers", .red)
        default: return nil
        }
    }

    var body: some View {
        if let label = label {
            Text(label.text).font(.caption).foregroundColor(label.color)
        }
    }
}

struct AvailabilityDot: View {
    let availability: Availability?
    /// A result from an earlier launch, shown as a ring while there is no current one.
    var previous: Availability?

    var body: some View {
        Group {
            if availability == .checking {
                ProgressView().controlSize(.mini)
            } else if availability == .queued {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .help("Waiting for its turn in the check")
            } else if let current = availability, let style = Self.style(current) {
                Circle().fill(style.color).frame(width: 9, height: 9)
                    .help(style.help)
            } else if let previous = previous, let style = Self.style(previous) {
                Circle().strokeBorder(style.color, lineWidth: 1.5).frame(width: 9, height: 9)
                    .help("Last check: \(style.help)")
            } else {
                Color.clear
            }
        }
        .frame(width: 12, height: 12)
    }

    private static func style(_ availability: Availability) -> (color: Color, help: String)? {
        switch availability {
        case .checking, .queued:
            return nil
        case let .available(kbps):
            return (.green, "Working: downloading at \(kbps) KB/s")
        case let .slow(kbps):
            return (.orange, kbps == 0
                ? "Video started, then stopped arriving (stalled)"
                : "Slow: only \(kbps) KB/s, likely to freeze")
        case .noVideo:
            return (.red, "Unavailable: peers found, but no video arrived")
        case .unavailable:
            return (.red, "Unavailable: no peers found")
        }
    }
}

final class HoverState: ObservableObject {
    @Published var isHovering = false
}

struct LinkRow: View {
    let link: StreamLink
    let isLoading: Bool
    let isPlaying: Bool
    let availability: Availability?
    /// Live transfer rate while the stream plays on the Mac or the TV.
    let rate: TransferRate?
    /// Who watches it right now (this Mac, other devices).
    let viewers: [Viewer]
    let onStop: () -> Void
    let onPlay: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if isPlaying {
                    // Hovering turns the speaker into a stop button for this stream only.
                    Button(action: onStop) {
                        Image(systemName: hover.isHovering ? "stop.circle.fill" : "speaker.wave.2.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Stop this stream")
                } else {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(hover.isHovering ? .accentColor : .secondary)
                }
            }
            .font(.system(size: 22))
            .frame(width: 26)

            AvailabilityDot(availability: availability, previous: link.lastResult)

            VStack(alignment: .leading, spacing: 2) {
                Text(link.name.isEmpty ? "Untitled link" : link.name)
                    .fontWeight(isLoading || isPlaying ? .semibold : .regular)
                HStack(spacing: 6) {
                    Text(link.shortHash)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(link.stream == nil ? .red : .secondary)
                    SpeedLabel(availability: availability)
                }
            }
            // The row separator starts under the title. Without this, the list lines it up
            // with the last label in the row ("This Mac · IINA" while it plays).
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer()
            if !viewers.isEmpty || rate != nil {
                HStack(spacing: 12) {
                    ViewersLabel(viewers: viewers)
                    if let rate = rate { TransferRateLabel(rate: rate) }
                }
            } else {
                lastSeenLabel
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.isHovering = $0 }
        .onTapGesture(perform: onPlay)
        .help("Click to play in your media player. ⌥-click to play alongside what's playing.")
    }

    /// When an availability check last found the link working. "Never seen" only once a
    /// check has found it dead, so unchecked links stay uncluttered.
    @ViewBuilder
    private var lastSeenLabel: some View {
        if let lastSeen = link.lastSeen {
            Text("Last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        } else if availability?.isDead == true {
            Text("Never seen")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// "▼ 608 KB/s  ▲ 12 KB/s · 3 peers", orange when the download is too slow to keep up.
struct TransferRateLabel: View {
    let rate: TransferRate

    static func format(_ kbps: Int) -> String {
        kbps >= 1024 ? String(format: "%.1f MB/s", Double(kbps) / 1024) : "\(kbps) KB/s"
    }

    var body: some View {
        let slow = rate.downKBps < LinkChecker.minimumKBps
        HStack(spacing: 6) {
            Text("▼ \(Self.format(rate.downKBps))")
                .foregroundColor(slow ? .orange : .secondary)
            Text("▲ \(Self.format(rate.upKBps))")
            Text("· \(rate.peers) peer\(rate.peers == 1 ? "" : "s")")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .monospacedDigit()
        .help(slow
            ? "Downloading slower than most streams need; playback may freeze."
            : "Downloading from and uploading to other peers, right now.")
    }
}

// MARK: - Status bar

/// Shared height of the bars along the bottom of the window (the sidebar's "New Channel" and
/// the status bar), so their edges line up.
enum BottomBar {
    static let rowHeight: CGFloat = 36
    static let dividerHeight: CGFloat = 1
}

struct StatusBar: View {
    @ObservedObject var status: PlaybackStatus
    @ObservedObject var nowPlaying = NowPlaying.shared
    @ObservedObject var transfers = TransferMonitor.shared
    let onStopAll: () -> Void
    let onStopStream: (String) -> Void
    let onSelectChannel: (UUID) -> Void

    @AppStorage("nowPlayingExpanded") private var expanded = false

    private var streams: [ActiveStream] { nowPlaying.streams }

    private var message: (icon: AnyView, text: String, isError: Bool)? {
        switch status.state {
        case let .working(text):
            return (AnyView(ProgressView().controlSize(.small)), text, false)
        case let .failed(text):
            return (AnyView(Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)), text, true)
        case .idle, .playing:
            return nil
        }
    }

    var body: some View {
        if message != nil || !streams.isEmpty {
            VStack(spacing: 0) {
                if expanded, streams.count > 1 {
                    NowPlayingPanel(
                        streams: streams, rates: transfers.rates,
                        onStop: onStopStream, onStopAll: onStopAll, onSelect: onSelectChannel
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    Divider()
                    if let message = message {
                        HStack(spacing: 8) {
                            message.icon
                            Text(message.text).lineLimit(2)
                            Spacer()
                            if message.isError {
                                Button("Dismiss") { status.dismiss() }
                            } else if streams.isEmpty {
                                Button("Stop", action: onStopAll)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(minHeight: BottomBar.rowHeight)
                    }
                    if !streams.isEmpty {
                        if message != nil { Divider() }
                        summary
                            .padding(.horizontal, 14)
                            .frame(height: BottomBar.rowHeight)
                    }
                }
                .font(.callout)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill").foregroundColor(.green)
            if streams.count == 1, let stream = streams.first {
                Text(stream.name).fontWeight(.semibold).lineLimit(1)
                ViewersLabel(viewers: stream.viewers)
                if let rate = transfers.rates[stream.hash] { TransferRateLabel(rate: rate) }
                Spacer(minLength: 8)
                Button { onStopStream(stream.hash) } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .disabled(!stream.playsOnMac)
                .help(stream.playsOnMac ? "Stop playing on this Mac"
                    : "Playing on another device; stop it there")
            } else {
                Text("\(streams.count) streams:").fontWeight(.semibold)
                Text(streams.map(\.name).joined(separator: " + "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !totalDown.isEmpty {
                    Text(totalDown).foregroundColor(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                }
                .help(expanded ? "Hide the list of streams" : "Show every stream playing")
            }
        }
    }

    private var totalDown: String {
        let rates = streams.compactMap { transfers.rates[$0.hash] }
        guard !rates.isEmpty else { return "" }
        return "· ▼ \(TransferRateLabel.format(rates.reduce(0) { $0 + $1.downKBps })) total"
    }
}

/// The expanded Now Playing list above the status bar: one row per stream, with who watches
/// it and how fast it moves. A floating card, so it reads apart from the list of links.
struct NowPlayingPanel: View {
    let streams: [ActiveStream]
    let rates: [String: TransferRate]
    let onStop: (String) -> Void
    let onStopAll: () -> Void
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button("Stop All", action: onStopAll)
                    .controlSize(.small)
                    .disabled(!streams.contains { $0.playsOnMac })
                    .help("Stop everything playing on this Mac. Other devices keep playing.")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider()
            ForEach(streams) { stream in
                row(stream)
                if stream.id != streams.last?.id { Divider().padding(.leading, 46) }
            }
        }
        .padding(.bottom, 4)
        .modifier(PanelBackground())
    }

    private func row(_ stream: ActiveStream) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = stream.channelIcon {
                    ChannelIconView(icon: icon, size: 24)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .frame(width: 24, height: 24)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(stream.name).lineLimit(1)
                if let channel = stream.channelName {
                    Text(channel).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 140, alignment: .leading)
            ViewersLabel(viewers: stream.viewers)
            Spacer(minLength: 8)
            if let rate = rates[stream.hash] { TransferRateLabel(rate: rate) }
            Button { onStop(stream.hash) } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .disabled(!stream.playsOnMac)
            .help(stream.playsOnMac ? "Stop playing on this Mac"
                : "Playing on another device; stop it there")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { stream.channelID.map(onSelect) }
    }
}

/// Liquid Glass where available; a material card with a shadow before macOS 26.
private struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

/// "This Mac · IINA", "Samsung BU8000 43 TV": who watches a stream. Other devices are
/// named after what they announce on the network, or shown by IP address.
struct ViewersLabel: View {
    let viewers: [Viewer]
    @ObservedObject private var names = LocalDeviceNames.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(viewers, id: \.self) { viewer in
                switch viewer {
                case let .thisMac(player):
                    Label(player.map { "This Mac · \($0)" } ?? "This Mac", systemImage: "laptopcomputer")
                        .help("Playing on this Mac")
                case let .device(address):
                    Label(names.names[address] ?? address, systemImage: "network")
                        .help("Playing on \(names.names[address].map { "\($0) (\(address))" } ?? address)")
                }
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
}
