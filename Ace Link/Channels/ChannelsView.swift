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
    var playFromClipboard: () -> Void
    var stop: () -> Void
    var checkAvailability: (UUID) -> Void
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
                StatusBar(status: status, onStop: actions.stop)
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
            channelList.safeAreaBar(edge: .bottom) { newChannelBar }
        } else {
            // No scroll edge effect: stack them so rows never scroll under the bar.
            VStack(spacing: 0) {
                channelList
                Divider()
                newChannelBar
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
        .padding(10)
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
                    AvailabilityDot(availability: checker.bestResult(for: channel))
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
                            onPlay: {
                                if NSEvent.modifierFlags.contains(.option) {
                                    actions.playAlongside(link)
                                } else {
                                    onPlay(link)
                                }
                            }
                        )
                        .contextMenu {
                            Button("Play") { onPlay(link) }
                            Button("Play Alongside") { actions.playAlongside(link) }
                                .disabled(status.playingLinkIDs.isEmpty || status.isBusy)
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

    var body: some View {
        Group {
            switch availability {
            case .checking:
                ProgressView().controlSize(.mini)
            case let .available(kbps):
                Circle().fill(Color.green).frame(width: 9, height: 9)
                    .help("Working: downloading at \(kbps) KB/s")
            case let .slow(kbps):
                Circle().fill(Color.orange).frame(width: 9, height: 9)
                    .help(kbps == 0
                        ? "Video started, then stopped arriving (stalled)"
                        : "Slow: only \(kbps) KB/s, likely to freeze")
            case .noVideo:
                Circle().fill(Color.red).frame(width: 9, height: 9)
                    .help("Unavailable: peers found, but no video arrived")
            case .unavailable:
                Circle().fill(Color.red).frame(width: 9, height: 9)
                    .help("Unavailable: no peers found")
            case nil:
                Color.clear
            }
        }
        .frame(width: 12, height: 12)
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
    let onPlay: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if isPlaying {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor)
                } else {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(hover.isHovering ? .accentColor : .secondary)
                }
            }
            .font(.system(size: 22))
            .frame(width: 26)

            AvailabilityDot(availability: availability)

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
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.isHovering = $0 }
        .onTapGesture(perform: onPlay)
        .help("Click to play in your media player. ⌥-click to play alongside what's playing.")
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var status: PlaybackStatus
    let onStop: () -> Void

    var body: some View {
        if status.state != .idle {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    switch status.state {
                    case .idle:
                        EmptyView()
                    case let .working(message):
                        ProgressView().controlSize(.small)
                        Text(message)
                    case let .playing(title):
                        Image(systemName: "play.fill").foregroundColor(.green)
                        Text("Playing: \(title)").lineLimit(1)
                    case let .failed(message):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(message).lineLimit(2)
                    }
                    Spacer()
                    if case .failed = status.state {
                        Button("Dismiss") { status.dismiss() }
                    } else {
                        Button("Stop", action: onStop)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}
