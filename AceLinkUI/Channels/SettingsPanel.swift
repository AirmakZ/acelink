import SwiftUI

/// The popover of the toolbar's settings button: the remote list's address, and
/// exporting or importing your own channels.
struct SettingsPanel: View {
    @ObservedObject var remote = RemoteList.shared
    @ObservedObject var store = ChannelStore.shared
    let onExport: () -> Void
    let onImport: () -> Void

    @State private var urlText = ""
    @FocusState private var urlFieldFocused: Bool

    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Empty is allowed: it turns the remote list off.
    private var isValidURL: Bool { trimmedURL.isEmpty || RemoteList.validURL(trimmedURL) != nil }
    private var urlChanged: Bool { trimmedURL != remote.urlString }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            remoteSection
            Divider()
            channelsSection
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            urlText = remote.urlString
            // Opened to set the first address (e.g. by picking Remote): type right away.
            if remote.urlString.isEmpty { urlFieldFocused = true }
        }
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote List").font(.headline)
            Text("An http(s) address of an m3u playlist, shown when the sidebar is switched " +
                "to Remote. Channels are grouped by group-title.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("https://…/list.m3u", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .onSubmit(saveURL)
                Button("Save", action: saveURL)
                    .disabled(!isValidURL || !urlChanged)
            }
            Group {
                if !isValidURL {
                    Text("Enter an address starting with http:// or https://.")
                        .foregroundColor(.red)
                } else if !urlChanged {
                    remoteStatus
                }
            }
            .font(.caption)
            Picker("Update every", selection: Binding(
                get: { remote.autoUpdateMinutes },
                set: { remote.setAutoUpdate(minutes: $0) }
            )) {
                ForEach(RemoteList.autoUpdateChoices, id: \.self) { minutes in
                    Text(Self.intervalName(minutes)).tag(minutes)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(remote.url == nil)
        }
    }

    /// "Never", "5 minutes", "1 hour"…
    private static func intervalName(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Never" }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(minutes) minutes"
    }

    @ViewBuilder
    private var remoteStatus: some View {
        switch remote.state {
        case .loading:
            Text("Updating…").foregroundColor(.secondary)
        case let .updated(date):
            Text("Updated at \(date.formatted(date: .omitted, time: .shortened)).")
                .foregroundColor(.secondary)
        case .failed:
            Text("Could not update: \(remote.failure ?? "unknown error"). Showing the saved copy.")
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if remote.url == nil {
                Text("No address set.").foregroundColor(.secondary)
            }
        }
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My Channels").font(.headline)
            Text("\(countText). Export them to a file to keep a copy or move them to " +
                "another Mac; importing adds a file's channels or replaces yours.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export…", action: onExport)
                    .disabled(store.channels.isEmpty)
                Button("Import…", action: onImport)
            }
        }
    }

    private var countText: String {
        let channels = store.channels.count
        let links = store.channels.reduce(0) { $0 + $1.links.count }
        return "\(channels) channel\(channels == 1 ? "" : "s"), \(links) link\(links == 1 ? "" : "s")"
    }

    private func saveURL() {
        guard isValidURL, urlChanged else { return }
        remote.setURL(trimmedURL)
    }
}
