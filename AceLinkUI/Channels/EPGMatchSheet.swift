import SwiftUI

/// "Match EPG…": picks the TV guide channel a link is sent with. Lists the guide channels
/// its name most likely means, with what each shows now; searching looks through the
/// whole guide.
struct EPGMatchSheet: View {
    let link: StreamLink
    let onDone: () -> Void

    @ObservedObject private var epg = EPGGuide.shared
    @State private var query = ""
    @State private var selected: GuideRef?

    init(link: StreamLink, onDone: @escaping () -> Void) {
        self.link = link
        self.onDone = onDone
        _selected = State(initialValue: EPGGuide.shared.guideChannel(for: link))
    }

    private var current: GuideRef? { epg.guideChannel(for: link) }

    private var options: [GuideRef] {
        guard epg.hasGuide else { return [] }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return epg.search(query) }
        var refs = epg.suggestions(for: [link.name])
        // The current one, even when it's no longer among the likely ones.
        if let current = current, !refs.contains(current) {
            refs.insert(current, at: 0)
        }
        return refs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Match EPG").font(.headline)
                Text(link.name.isEmpty ? "Untitled channel" : link.name)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Search the guide", text: $query)
                .textFieldStyle(.roundedBorder)
            List(selection: $selected) {
                Section(query.isEmpty ? "Suggestions" : "Results") {
                    ForEach(options, id: \.self) { ref in
                        row(ref).tag(ref)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 300)
            .overlay {
                if options.isEmpty {
                    Text(query.isEmpty ? "No similar channels in the guide" : "No results")
                        .foregroundColor(.secondary)
                }
            }
            Text(currentText)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Automatic") { choose(.automatic) }
                    .help("Match the guide by the channel's name")
                Button("No Guide") { choose(.none) }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Match") {
                    if let selected = selected { choose(.channel(selected)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(_ ref: GuideRef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ref.id)
                    if let label = epg.sourceLabel(ref) {
                        Text(label).font(.caption).foregroundColor(.secondary)
                    }
                }
                if let now = epg.nowShowing(ref) {
                    Text("Now: \(now)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(now)
                }
            }
            Spacer()
            if ref == current {
                Image(systemName: "checkmark").foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Currently: M+ LaLiga HD, matched by name."
    private var currentText: String {
        let name = current.map { ref in
            epg.sourceLabel(ref).map { "\(ref.id) (\($0))" } ?? ref.id
        }
        switch epg.choice(for: link) {
        case .none: return "Currently: no guide, chosen."
        case .channel: return "Currently: \(name ?? "?"), chosen."
        case .automatic:
            guard let name = name else { return "Currently: no guide, nothing matches the name." }
            return "Currently: \(name), matched by name."
        }
    }

    private func choose(_ choice: EPGGuide.Choice) {
        epg.setChoice(choice, for: link)
        onDone()
    }
}

/// The popover of a link's calendar icon: what its guide channel shows now and next.
struct EPGInfoView: View {
    let ref: GuideRef
    /// Picked with "Match EPG…" rather than matched by name.
    let chosen: Bool
    let onMatch: () -> Void

    @ObservedObject private var epg = EPGGuide.shared

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private func hours(_ programme: EPGGuide.Programme) -> String {
        "\(Self.time.string(from: programme.start)) – \(Self.time.string(from: programme.stop))"
    }

    /// A programme's full title, then its time, details line and description.
    private static func tooltip(_ programme: EPGGuide.Programme, hours: String) -> String {
        [programme.title, [hours, programme.subtitle ?? programme.category].compactMap { $0 }
            .joined(separator: " · "), programme.details]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    var body: some View {
        let schedule = epg.schedule(ref, count: 6)
        let current = schedule.first { $0.isOn }
        let next = schedule.filter { !$0.isOn }.prefix(5)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(ref.id, systemImage: "calendar").font(.headline)
                Spacer()
                Text([epg.sourceLabel(ref), chosen ? "Chosen" : "Matched by name"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let current = current {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Now").font(.caption).foregroundColor(.secondary)
                    Text(current.title).font(.title3).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: current.progress)
                    HStack {
                        Text(hours(current))
                        // dobleM puts genre, year and rating in the sub-title.
                        if let more = current.subtitle ?? current.category {
                            Text("· \(more)").lineLimit(1).help(more)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    if let details = current.details {
                        Text(details)
                            .font(.callout)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                            .help(details)
                    }
                }
            } else {
                Text("Nothing on right now.").foregroundColor(.secondary)
            }

            // Only the next hours are kept of channels nothing matched until now.
            if epg.guides[ref.source]?.hasFullSchedule(ref.id) == false {
                Text(epg.states[ref.source] == .loading
                    ? "Downloading the full schedule…"
                    : "Only the next hours; the full schedule comes with the next update.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !next.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Up Next").font(.caption).foregroundColor(.secondary)
                    ForEach(next) { programme in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.time.string(from: programme.start))
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 48, alignment: .leading)
                            Text(programme.title).font(.callout).lineLimit(1)
                        }
                        // The whole row, so the pointer needn't land on the text itself.
                        .contentShape(Rectangle())
                        .help(Self.tooltip(programme, hours: hours(programme)))
                    }
                }
            } else if current == nil {
                Text("The guide has no more programmes for this channel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
            HStack {
                Spacer()
                Button("Match EPG…", action: onMatch)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { epg.ensureSchedules(for: [ref]) }
    }
}
