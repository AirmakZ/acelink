import SwiftUI

/// The toolbar's "Live Today" popover: today's live events (marked in the TV guide) on the
/// guide channels of your links, by time. Typing filters them.
struct LiveEventsView: View {
    @ObservedObject var checker: LinkChecker
    let onPlay: (StreamLink) -> Void
    /// Plays the best of an event's links (double click).
    let onPlayBest: ([StreamLink]) -> Void

    @ObservedObject private var epg = EPGGuide.shared
    @ObservedObject private var filter = LiveFilter.shared
    @State private var events: [EPGGuide.LiveEvent] = []
    @State private var query = ""
    /// Also the events the settings hide.
    @State private var showsHidden = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Today's events that the settings let through.
    private var allowed: [EPGGuide.LiveEvent] {
        showsHidden ? events : events.filter { filter.shows($0.programme) }
    }

    private var hiddenCount: Int {
        events.filter { !filter.shows($0.programme) }.count
    }

    /// The events with every word of the search in their title, competition, guide channel
    /// or links' names.
    private var shown: [EPGGuide.LiveEvent] {
        let events = allowed
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return events }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return events.filter { event in
            let text = ([event.programme.title, event.programme.subtitle,
                         event.programme.category, event.ref.id]
                .compactMap { $0 } + event.links.map(\.name))
                .joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: options) != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Today").font(.headline)
            TextField("Search events, competitions or channels", text: $query)
                .textFieldStyle(.roundedBorder)
            if hiddenCount > 0 {
                HStack(spacing: 4) {
                    Text(showsHidden
                        ? "Showing \(hiddenCount) hidden by your settings."
                        : "\(hiddenCount) hidden by your settings.")
                    Button(showsHidden ? "Hide Them" : "Show All") { showsHidden.toggle() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            // Every half minute, so what's on now and its progress stay current.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                ScrollViewReader { proxy in
                    List(shown) { event in
                        row(event).id(event.id)
                    }
                    .listStyle(.inset)
                    .onAppear {
                        // Past what already ended.
                        guard let next = events.first(where: { $0.programme.stop > Date() })
                        else { return }
                        DispatchQueue.main.async { proxy.scrollTo(next.id, anchor: .top) }
                    }
                }
            }
            .frame(height: 420)
            .overlay {
                if shown.isEmpty {
                    Text(events.isEmpty
                        ? "No live events today on your channels' guides."
                        : allowed.isEmpty
                        ? "Your settings hide all of today's live events."
                        : "No live events match “\(query)”.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            if epg.isUpdating {
                Text("Updating the TV guide…").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            reload()
            // Channels matched since the last download only have the next hours.
            epg.ensureSchedules(for: Set(events.map(\.ref)).union(guideRefs()))
        }
        .onChange(of: epg.states) { _ in reload() }
    }

    private func reload() {
        events = epg.liveEventsToday()
        filter.learn(from: epg)
    }

    /// The guide channels of every link, also those without live events yet.
    private func guideRefs() -> Set<GuideRef> {
        let links = (ChannelStore.shared.channels + RemoteList.shared.store.channels)
            .flatMap(\.links)
        return Set(links.compactMap(epg.guideChannel))
    }

    private func row(_ event: EPGGuide.LiveEvent) -> some View {
        let programme = event.programme
        let ended = programme.stop <= Date()
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.time.string(from: programme.start))
                    Text(Self.time.string(from: programme.stop))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if programme.isOn {
                            Text("LIVE")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.red))
                        }
                        Text(programme.plainTitle)
                            .fontWeight(programme.isOn ? .semibold : .regular)
                            .lineLimit(2)
                    }
                    Text(event.links.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if programme.isOn {
                        ProgressView(value: programme.progress)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Not over the play control, which needs its own clicks.
            .overlay(AppKitToolTip(text: tooltip(event)) { onPlayBest(event.links) })

            playControl(event)
        }
        .padding(.vertical, 3)
        .opacity(ended ? 0.45 : 1)
        .contextMenu {
            Button("Hide “\(LiveFilter.competition(of: programme))”") {
                filter.setShown(LiveFilter.competition(of: programme), false)
            }
            if programme.isMagazine {
                Button("Hide Previews and Talk Shows") { filter.setHidesMagazines(true) }
            }
        }
    }

    /// One link plays at once; several are picked from a menu.
    private func playControl(_ event: EPGGuide.LiveEvent) -> some View {
        Button {
            if event.links.count == 1, let link = event.links.first {
                onPlay(link)
            } else {
                showLinkMenu(event.links)
            }
        } label: {
            Image(systemName: "play.circle.fill").font(.title2)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .accessibilityLabel(event.links.count == 1 ? "Play \(event.links[0].name)" : "Play…")
    }

    /// The event's links, each with its state's dot, under the pointer. AppKit's menu, as
    /// SwiftUI's leaves out the items' images on some macOS versions.
    private func showLinkMenu(_ links: [StreamLink]) {
        let menu = NSMenu()
        let target = MenuTarget()
        for link in links {
            let item = NSMenuItem(
                title: link.name, action: #selector(MenuTarget.pick(_:)), keyEquivalent: ""
            )
            item.target = target
            item.image = dotImage(for: link) ?? Self.noDot
            // macOS 27 hides menu item images unless asked to show them.
            if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
            item.representedObject = { onPlay(link) }
            menu.addItem(item)
        }
        // Blocks until the menu closes, so `target` lives long enough.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        _ = target
    }

    /// Calls the closure of the menu item that was picked.
    private final class MenuTarget: NSObject {
        @objc func pick(_ item: NSMenuItem) {
            (item.representedObject as? () -> Void)?()
        }
    }

    /// Room for a dot, so names without one line up with the rest.
    private static let noDot = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { _ in
        true
    }

    /// The link's state as in the lists: a dot for this session's check, a ring for an
    /// earlier one. Drawn as a bitmap because menus show SF Symbols without their color.
    private func dotImage(for link: StreamLink) -> NSImage? {
        let current = checker.results[link.id].flatMap { $0.isPending ? nil : $0 }
        guard let result = current ?? link.lastResult,
              let style = AvailabilityDot.style(result) else { return nil }
        let color = NSColor(style.color)
        let filled = current != nil
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if filled {
                color.setFill()
                circle.fill()
            } else {
                color.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The full title, the guide channel and its links, then the description.
    private func tooltip(_ event: EPGGuide.LiveEvent) -> String {
        let programme = event.programme
        return [
            programme.plainTitle,
            ([event.ref.id] + [programme.subtitle ?? programme.category].compactMap { $0 })
                .joined(separator: " · "),
            "Channels: " + event.links.map(\.name).joined(separator: ", "),
            programme.details,
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }
}

/// Which live events Live Today shows: previews and talk shows, and each competition.
/// Competitions are learned from the guide as they turn up and shown until turned off, so
/// only the hidden ones are saved. Those not seen for 30 days are forgotten.
final class LiveFilter: ObservableObject {
    static let shared = LiveFilter()

    /// Events whose title names no competition.
    static let other = "Other"
    static let forgetAfter: TimeInterval = 30 * 24 * 3600

    private static let magazinesKey = "liveHideMagazines"
    private static let hiddenKey = "liveHiddenCompetitions"
    private static let knownKey = "liveCompetitions"

    /// Hides the guide's "Sports magazines": previews, talk shows, press conferences.
    @Published private(set) var hidesMagazines =
        UserDefaults.standard.object(forKey: magazinesKey) as? Bool ?? true
    @Published private(set) var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    /// Every competition seen, with when it was last seen.
    @Published private(set) var known =
        UserDefaults.standard.dictionary(forKey: knownKey) as? [String: Date] ?? [:]
    /// Live events from today on per competition, from the last `learn`.
    @Published private(set) var counts: [String: Int] = [:]

    static func competition(of programme: EPGGuide.Programme) -> String {
        programme.competition ?? other
    }

    /// The known competitions by name, "Other" last.
    var names: [String] {
        known.keys.sorted { first, second in
            if (first == Self.other) != (second == Self.other) { return second == Self.other }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
    }

    func shows(_ programme: EPGGuide.Programme) -> Bool {
        if hidesMagazines, programme.isMagazine { return false }
        return !hidden.contains(Self.competition(of: programme))
    }

    /// Adds the competitions of the live events from today on, counts them and forgets
    /// those not seen for a month. Previews and talk shows count only while they're shown,
    /// so a competition that only has those isn't listed for nothing. Call on the main
    /// thread.
    func learn(from guide: EPGGuide) {
        let now = Date()
        let events = guide.liveEvents(
            from: Calendar.current.startOfDay(for: now), to: .distantFuture
        )
        var counts: [String: Int] = [:]
        for event in events where !(hidesMagazines && event.programme.isMagazine) {
            counts[Self.competition(of: event.programme), default: 0] += 1
        }
        var known = self.known.filter { now.timeIntervalSince($0.value) < Self.forgetAfter }
        for name in counts.keys { known[name] = now }
        self.counts = counts
        if known != self.known {
            self.known = known
            UserDefaults.standard.set(known, forKey: Self.knownKey)
        }
        let hidden = self.hidden.filter { known[$0] != nil }
        if hidden != self.hidden { save(hidden: hidden) }
    }

    func setShown(_ name: String, _ shown: Bool) {
        var hidden = self.hidden
        if shown { hidden.remove(name) } else { hidden.insert(name) }
        save(hidden: hidden)
    }

    func setAllShown(_ shown: Bool) {
        save(hidden: shown ? [] : Set(known.keys))
    }

    func setHidesMagazines(_ hides: Bool) {
        hidesMagazines = hides
        UserDefaults.standard.set(hides, forKey: Self.magazinesKey)
        learn(from: EPGGuide.shared)
    }

    private func save(hidden: Set<String>) {
        self.hidden = hidden
        UserDefaults.standard.set(hidden.sorted(), forKey: Self.hiddenKey)
    }
}
