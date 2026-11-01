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
    var playFromClipboard: () -> Void
    var stop: () -> Void
}

/// View state for ChannelsView. (An ObservableObject instead of @State so the app
/// also builds with the Command Line Tools, which lack the SwiftUI macro plugin.)
final class ChannelsUIState: ObservableObject {
    @Published var selection: UUID?
    @Published var editingChannel: Channel?
    @Published var editingLink: LinkEditTarget?
    @Published var channelPendingDelete: Channel?
}

struct ChannelsView: View {
    @ObservedObject var store: ChannelStore
    @ObservedObject var status: PlaybackStatus
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
                        onPlay: actions.play,
                        onEditChannel: { ui.editingChannel = channel },
                        onEditLink: { ui.editingLink = $0 }
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

    private var sidebar: some View {
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
                    Divider()
                    Button("Delete Channel…") { ui.channelPendingDelete = channel }
                }
            }
            .onMove(perform: store.moveChannels)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
    let onPlay: (StreamLink) -> Void
    let onEditChannel: () -> Void
    let onEditLink: (LinkEditTarget) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if channel.links.isEmpty {
                VStack(spacing: 10) {
                    Text("No links in this channel").font(.title3)
                    Text("Add an AceStream link (hash, acestream:// or magnet:).")
                        .foregroundColor(.secondary)
                    Button("Add Link", action: addLink)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(channel.links) { link in
                        LinkRow(
                            link: link,
                            isActive: status.activeLinkID == link.id,
                            isBusy: status.isBusy,
                            onPlay: { onPlay(link) }
                        )
                        .contextMenu {
                            Button("Play") { onPlay(link) }
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
            Button("Edit", action: onEditChannel)
            Button(action: addLink) {
                Label("Add Link", systemImage: "plus")
            }
            .keyboardShortcut("l")
        }
        .padding(16)
    }

    private func addLink() {
        let draft = LinkEditor.draftFromClipboard(defaultName: "Link \(channel.links.count + 1)")
        onEditLink(LinkEditTarget(channelID: channel.id, link: draft, isNew: true))
    }
}

final class HoverState: ObservableObject {
    @Published var isHovering = false
}

struct LinkRow: View {
    let link: StreamLink
    let isActive: Bool
    let isBusy: Bool
    let onPlay: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isActive, isBusy {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor)
                } else {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(hover.isHovering ? .accentColor : .secondary)
                }
            }
            .font(.system(size: 22))
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(link.name.isEmpty ? "Untitled link" : link.name)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(link.shortHash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(link.stream == nil ? .red : .secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.isHovering = $0 }
        .onTapGesture(perform: onPlay)
        .help("Click to play in your media player")
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
                        Button("Dismiss") { status.set(.idle) }
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
