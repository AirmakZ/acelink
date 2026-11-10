import SwiftUI

struct TVSharePanel: View {
    @ObservedObject var tv: TVShare
    @ObservedObject var checker = LinkChecker.shared
    @ObservedObject var store = ChannelStore.shared
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { tv.isEnabled }, set: onToggle)) {
                Text("Share to TV").font(.headline)
            }
            .toggleStyle(.switch)

            Text("Keeps the AceStream engine running and serves all your channels as a " +
                "playlist on your home network. Add the address below once in an IPTV app " +
                "on your TV (e.g. m3u-ip.tv).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusLine

            if tv.isEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlist address").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Text(tv.playlistURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tv.playlistURL, forType: .string)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                }

                hideDeadLinksToggle

                Text("• The Mac won't sleep while this is on (the screen still can).\n" +
                    "• Playing a link on the Mac shares the same engine, so the TV keeps playing.\n" +
                    "• Changes to your channels show up when the TV app reloads the playlist.\n" +
                    "• Tip: reserve this Mac's IP in your router so the address never changes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var hiddenCount: Int {
        let dead = TVShare.deadLinkIDs()
        return store.channels.reduce(0) { $0 + $1.links.filter { dead.contains($0.id) }.count }
    }

    private var hideDeadLinksToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Hide links that failed the last check", isOn: $tv.hideDeadLinks)
            Text(tv.hideDeadLinks && hiddenCount > 0
                ? "\(hiddenCount) red link\(hiddenCount == 1 ? " is" : "s are") hidden from the TV. " +
                "Check the channel again to bring back links that work again."
                : "Red links from Check Availability are left out of the TV playlist.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            switch tv.state {
            case .off:
                Circle().fill(Color.secondary).frame(width: 8, height: 8)
                Text("Off")
            case let .starting(message):
                ProgressView().controlSize(.small)
                Text(message)
            case .on:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Ready — the TV can play your channels")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(message)
            }
        }
        .font(.callout)
    }
}
