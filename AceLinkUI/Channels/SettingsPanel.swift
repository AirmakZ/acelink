import SwiftUI

/// The popover of the toolbar's settings button: the remote list's address, and
/// exporting or importing your own channels.
struct SettingsPanel: View {
    @ObservedObject var remote = RemoteList.shared
    @ObservedObject var store = ChannelStore.shared
    let onExport: () -> Void
    let onImport: () -> Void

    @ObservedObject var epg = EPGGuide.shared
    @State private var urlText = ""
    @State private var guideURLText = ""
    @FocusState private var urlFieldFocused: Bool

    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Empty is allowed: it turns the remote list off.
    private var isValidURL: Bool { trimmedURL.isEmpty || RemoteList.validURL(trimmedURL) != nil }
    private var urlChanged: Bool { trimmedURL != remote.urlString }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            remoteSection
            Divider()
            guideSection
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

    private var trimmedGuideURL: String {
        guideURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddGuide: Bool {
        RemoteList.validURL(trimmedGuideURL) != nil
            && !epg.sources.contains { $0.url == trimmedGuideURL }
    }

    private var guideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TV Guide").font(.headline)
            Text("XMLTV guides (.xml or .xml.gz) sent with the Share to TV playlist. Channels " +
                "are matched by name in these guides in order, so later ones fill in what " +
                "earlier ones lack; a name tagged with a country, like (DE), looks in that " +
                "country's guide first. Right-click a channel " +
                "and choose Match EPG to pick another.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Send a TV guide to the TV", isOn: Binding(
                get: { epg.isEnabled },
                set: { epg.setEnabled($0) }
            ))
            if epg.isEnabled {
                VStack(spacing: 0) {
                    ForEach(Array(epg.sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Divider() }
                        sourceRow(source, index: index)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor)))
                HStack {
                    TextField("https://…/guide.xml.gz", text: $guideURLText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addGuide)
                    Menu("Suggested") {
                        ForEach(EPGGuide.suggestedSources, id: \.url) { suggestion in
                            Button(suggestion.name) { epg.addSource(suggestion.url) }
                                .disabled(epg.sources.contains { $0.url == suggestion.url })
                        }
                    }
                    .fixedSize()
                    Button("Add", action: addGuide).disabled(!canAddGuide)
                }
                HStack {
                    Text(epg.isUpdating ? "Downloading guides…" : matchedText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Update Now") { epg.refresh() }
                        .controlSize(.small)
                        .disabled(epg.isUpdating || !epg.sources.contains(where: \.isEnabled))
                }
            }
        }
    }

    /// A source: on/off, its place in the order, name, state, move and remove buttons.
    private func sourceRow(_ source: EPGSource, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { epg.setSource(source.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(index + 1). \(source.label)").lineLimit(1)
                Text(sourceStatus(source))
                    .font(.caption)
                    .foregroundColor(sourceFailed(source) ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help("\(source.url)\n\(sourceStatus(source))")
            Spacer()
            Button { epg.moveSource(source.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Look in this guide earlier")
            Button { epg.moveSource(source.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == epg.sources.count - 1)
                .help("Look in this guide later")
            Button { epg.removeSource(source.id) } label: { Image(systemName: "minus.circle") }
                .help("Remove this guide")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func sourceFailed(_ source: EPGSource) -> Bool {
        if case .failed = epg.states[source.id] { return true }
        return false
    }

    /// "612 channels · updated at 20:30", "Downloading…", "Could not update: …"
    private func sourceStatus(_ source: EPGSource) -> String {
        let channels = epg.guides[source.id].map { "\($0.channelCount) channels" }
        switch epg.states[source.id] {
        case .loading:
            return "Downloading…"
        case let .updated(date):
            return [channels, "updated at \(date.formatted(date: .omitted, time: .shortened))"]
                .compactMap { $0 }.joined(separator: " · ")
        case let .failed(message):
            return "Could not update: \(message)." + (channels != nil ? " Using the saved copy." : "")
        case nil:
            return source.isEnabled ? (channels ?? "Not downloaded yet") : "Off"
        }
    }

    /// "320 of 432 channels have a guide."
    private var matchedText: String {
        let links = (store.channels + remote.store.channels).flatMap(\.links)
        return "\(epg.matchedCount(of: links)) of \(links.count) channels have a guide."
    }

    private func addGuide() {
        guard canAddGuide else { return }
        epg.addSource(trimmedGuideURL)
        guideURLText = ""
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My Groups").font(.headline)
            Text("\(countText). Export them to a file to keep a copy or move them to " +
                "another Mac; importing adds a file's groups or replaces yours.")
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
        return "\(channels) group\(channels == 1 ? "" : "s"), \(links) channel\(links == 1 ? "" : "s")"
    }

    private func saveURL() {
        guard isValidURL, urlChanged else { return }
        remote.setURL(trimmedURL)
    }
}
