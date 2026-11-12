import Foundation
import os

/// One XMLTV guide in the ordered list of "TV Guide" sources (Settings).
struct EPGSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var isEnabled = true

    /// The file name without extensions: "guiatv", "epg_ripper_DE1".
    var label: String {
        var name = URL(string: url)?.lastPathComponent ?? url
        for ext in [".gz", ".xml"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return name.isEmpty ? url : name
    }

    /// The country in the file name ("DE" for epg_ripper_DE1.xml.gz), so names tagged
    /// "(DE)" look in this guide first.
    var country: String? {
        guard let match = label.range(of: #"[_\-.]([A-Za-z]{2})\d*$"#, options: .regularExpression)
        else { return nil }
        return String(label[match].dropFirst().prefix(2)).uppercased()
    }
}

/// A channel in one of the guides.
struct GuideRef: Hashable {
    let source: UUID
    let id: String
}

/// The TV guide sent with "Share to TV": XMLTV files from an ordered list of sources (EPG
/// dobleM, which covers Spanish TV and Movistar+/DAZN, by default), matched to the channels
/// by name. A name is looked up in the sources in order, so later ones fill in the channels
/// earlier ones lack. The TV playlist points to `/epg.xml` (`url-tvg`) and gives each entry
/// the `tvg-id` of its match; `/epg.xml` serves only the matched channels.
///
/// Guides are big (dobleM is ~100 MB), so after each download only the channel list, the full
/// schedule of the matched channels and the next few hours of the rest are kept on disk.
final class EPGGuide: ObservableObject {
    static let shared = EPGGuide()

    static let path = "/epg.xml"
    static let defaultURL =
        "https://raw.githubusercontent.com/davidmuma/EPG_dobleM/master/guiatv.xml.gz"
    /// Offered in Settings to fill in channels dobleM doesn't have.
    static let suggestedSources: [(name: String, url: String)] = [
        ("EPG dobleM (Spain)", defaultURL),
    ] + [
        ("United Kingdom", "UK1"), ("Germany", "DE1"), ("Portugal", "PT1"),
        ("Netherlands", "NL1"), ("Poland", "PL1"), ("France", "FR1"), ("Italy", "IT1"),
        ("Turkey", "TR1"), ("Spain", "ES1"),
    ].map { name, file in
        ("epgshare01: \(name)", "https://epgshare01.online/epgshare01/epg_ripper_\(file).xml.gz")
    }

    /// How often the guides are downloaded again while the app runs.
    private static let updateEvery: TimeInterval = 12 * 60 * 60
    /// Of the channels nothing matches, how much schedule is kept: enough for "Match EPG…"
    /// to show what's on, and for a newly chosen channel until the next download.
    static let previewHours: TimeInterval = 6

    enum State: Equatable {
        case loading
        case updated(Date)
        case failed(String)
    }

    private static let enabledKey = "epgEnabled"
    private static let sourcesKey = "epgSources"
    private static let choicesKey = "epgChoices"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var sources: [EPGSource]
    @Published private(set) var states: [UUID: State] = [:]
    /// The loaded guides, by source. A disabled source keeps its guide but isn't used.
    @Published private(set) var guides: [UUID: Guide] = [:]

    /// A link's guide, picked with "Match EPG…".
    enum Choice: Equatable {
        /// Matched by name (or the channel's guide ID).
        case automatic
        /// No guide, even if the name matches one.
        case none
        case channel(GuideRef)
    }

    /// The links' choices by stream hash (lowercase), so they also work for the remote list,
    /// whose links are read again on every update: "<source UUID>|<channel ID>", or empty
    /// for `.none`. A bare channel ID (from before there were several sources) is the first.
    @Published private(set) var choices = UserDefaults.standard
        .dictionary(forKey: choicesKey) as? [String: String] ?? [:]

    /// Names already matched (or not: nil), by name. Main thread only.
    private var matches: [String: GuideRef?] = [:]
    private var updateTimer: Timer?
    /// Sources waiting to be downloaded, one at a time to keep memory down.
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?

    private static var cacheDir: URL { ChannelStore.baseDir.appendingPathComponent("epg") }
    private static func cacheURL(_ id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString).xml")
    }

    /// Call on the main thread: the update timer runs on the main run loop.
    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
           let saved = try? JSONDecoder().decode([EPGSource].self, from: data) {
            sources = saved
        } else {
            // The single address of earlier versions, and its copy of the guide.
            let url = UserDefaults.standard.string(forKey: "epgURL") ?? Self.defaultURL
            let source = EPGSource(url: url)
            sources = [source]
            let old = ChannelStore.baseDir.appendingPathComponent("epg.xml")
            try? FileManager.default.createDirectory(at: Self.cacheDir,
                                                     withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: Self.cacheURL(source.id))
            saveSources()
        }
        if isEnabled { start() }
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.sourcesKey)
        }
        guidesChanged()
    }

    /// The enabled sources with a guide, in order.
    var activeGuides: [(source: EPGSource, guide: Guide)] {
        sources.compactMap { source in
            guard source.isEnabled, let guide = guides[source.id] else { return nil }
            return (source, guide)
        }
    }

    var hasGuide: Bool { isEnabled && !activeGuides.isEmpty }

    var isUpdating: Bool { states.values.contains(.loading) }

    /// When the last guide was updated, if all went well.
    var lastUpdate: Date? {
        states.values.compactMap { state -> Date? in
            if case let .updated(date) = state { return date }
            return nil
        }.max()
    }

    func source(_ id: UUID) -> EPGSource? { sources.first { $0.id == id } }

    private func guidesChanged() {
        matches = [:]
        objectWillChange.send()
    }

    // MARK: - On / off and sources

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            updateTimer?.invalidate()
            updateTimer = nil
            queue = []
            guides = [:]
            states = [:]
            guidesChanged()
        }
    }

    /// Adds a source at the end and downloads it. Returns false for a duplicate address.
    @discardableResult
    func addSource(_ url: String) -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteList.validURL(url) != nil, !sources.contains(where: { $0.url == url }) else {
            return false
        }
        let source = EPGSource(url: url)
        sources.append(source)
        saveSources()
        refresh([source.id])
        return true
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        queue.removeAll { $0 == id }
        guides[id] = nil
        states[id] = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(id))
        saveSources()
    }

    func moveSource(_ id: UUID, by offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard sources.indices.contains(target) else { return }
        sources.swapAt(index, target)
        saveSources()
    }

    func setSource(_ id: UUID, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        saveSources()
        if enabled, isEnabled, guides[id] == nil { load([id]) }
    }

    // MARK: - Downloading

    /// Reads the copies on disk, then downloads the ones older than `updateEvery`.
    private func start() {
        scheduleUpdates()
        load(sources.filter { $0.isEnabled && guides[$0.id] == nil }.map(\.id))
    }

    /// Reads these sources' copies on disk, and downloads those that have none or are old.
    private func load(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let loaded = ids.map { id -> (UUID, Guide?, Date?) in
                let file = Self.cacheURL(id)
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                let guide = (try? Data(contentsOf: file, options: .alwaysMapped))
                    .flatMap { Guide(data: $0, requireProgrammes: false) }
                return (id, guide, modified)
            }
            DispatchQueue.main.async {
                guard self.isEnabled else { return }
                var stale: [UUID] = []
                for (id, guide, modified) in loaded where self.source(id) != nil {
                    if let guide = guide, self.guides[id] == nil {
                        self.guides[id] = guide
                        if let modified = modified { self.states[id] = .updated(modified) }
                    }
                    if guide == nil || Date().timeIntervalSince(modified ?? .distantPast)
                        > Self.updateEvery {
                        stale.append(id)
                    }
                }
                self.guidesChanged()
                self.refresh(stale)
            }
        }
    }

    private func scheduleUpdates() {
        updateTimer?.invalidate()
        let timer = Timer(timeInterval: Self.updateEvery, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Downloads these sources again (all enabled ones by default), one after the other.
    func refresh(_ ids: [UUID]? = nil) {
        guard isEnabled else { return }
        for id in ids ?? sources.filter(\.isEnabled).map(\.id)
            where !queue.contains(id) && states[id] != .loading {
            queue.append(id)
            states[id] = .loading
        }
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { @MainActor in
            while !queue.isEmpty {
                await update(queue.removeFirst())
            }
            worker = nil
        }
    }

    @MainActor
    private func update(_ id: UUID) async {
        guard isEnabled, let source = source(id), source.isEnabled,
              let url = RemoteList.validURL(source.url) else {
            if states[id] == .loading { states[id] = nil }
            return
        }
        let unchanged = { [weak self] in self?.isEnabled == true && self?.source(id) == source }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 60
            // Retried once: a download now and then stalls until it times out.
            let (download, response): (Data, URLResponse)
            do {
                (download, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                (download, response) = try await URLSession.shared.data(for: request)
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GuideError("The server answered \(http.statusCode)")
            }
            // Unzipping and indexing take a moment: keep them off the main thread.
            let full = try await Task.detached(priority: .utility) { () -> Guide in
                guard let guide = Guide(data: try Self.gunzipped(download),
                                        requireProgrammes: true) else {
                    throw GuideError("The file is not an XMLTV guide")
                }
                return guide
            }.value
            guard unchanged() else { return }

            // Match with the whole guide in place, to know which channels need a schedule.
            guides[id] = full
            guidesChanged()
            let needed = neededIDs(in: id)

            let file = Self.cacheURL(id)
            let kept = await Task.detached(priority: .utility) { () -> Guide? in
                let data = full.trimmed(keeping: needed, previewHours: Self.previewHours)
                try? FileManager.default.createDirectory(at: Self.cacheDir,
                                                         withIntermediateDirectories: true)
                guard (try? data.write(to: file, options: .atomic)) != nil,
                      let mapped = try? Data(contentsOf: file, options: .alwaysMapped)
                else { return nil }
                return Guide(data: mapped, requireProgrammes: false)
            }.value
            guard unchanged() else {
                if self.source(id) == nil { guides[id] = nil }
                return
            }
            // Keep the whole guide in memory if the trimmed copy couldn't be saved.
            guides[id] = kept ?? full
            guidesChanged()
            states[id] = .updated(Date())
            os_log("TV guide %{public}@ updated: %d channels, %d with a full schedule",
                   source.label, full.channelCount, needed.count)
        } catch {
            os_log("Cannot update the TV guide %{public}@: %{public}@", source.label,
                   error.localizedDescription)
            if unchanged() { states[id] = .failed(error.localizedDescription) }
        }
    }

    /// The channels of this source that links use, by name, choice or guide ID.
    /// Call on the main thread.
    private func neededIDs(in source: UUID) -> Set<String> {
        var ids: Set<String> = []
        for channel in ChannelStore.shared.channels + RemoteList.shared.store.channels {
            for link in channel.links {
                if let ref = guideChannel(for: link), ref.source == source {
                    ids.insert(ref.id)
                }
            }
        }
        for value in choices.values {
            if let ref = decodeChoice(value), ref.source == source { ids.insert(ref.id) }
        }
        return ids
    }

    /// Downloads again the sources of channels whose full schedule wasn't kept (newly
    /// matched or chosen), at most every 10 minutes each. Call on the main thread.
    func ensureSchedules(for refs: Set<GuideRef>) {
        var stale: Set<UUID> = []
        for ref in refs where guides[ref.source]?.hasFullSchedule(ref.id) == false {
            if case let .updated(date) = states[ref.source], Date().timeIntervalSince(date) < 600 {
                continue
            }
            stale.insert(ref.source)
        }
        if !stale.isEmpty { refresh(Array(stale)) }
    }

    struct GuideError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Matching

    /// The guide channel of a link: its choice ("Match EPG…"), else what its name matches.
    /// The name of the channel it's in isn't used: that's a group of links ("DAZN", "Sport
    /// TV"), not a TV channel. Call on the main thread.
    func guideChannel(for link: StreamLink) -> GuideRef? {
        guard hasGuide else { return nil }
        switch choice(for: link) {
        case .none: return nil
        case let .channel(ref) where isActive(ref.source): return ref
        default: return match(link.name)
        }
    }

    /// The `tvg-id` of a link in the playlist. Call on the main thread.
    func tvgID(for link: StreamLink) -> String? {
        guideChannel(for: link).map(servedID)
    }

    private func isActive(_ source: UUID) -> Bool {
        self.source(source)?.isEnabled == true && guides[source] != nil
    }

    /// The channel ID as served to the TV: as in its guide, unless an earlier source has a
    /// channel with the same ID; then it's prefixed with the source's label.
    func servedID(_ ref: GuideRef) -> String {
        for (source, guide) in activeGuides {
            if source.id == ref.source { return ref.id }
            if guide.contains(ref.id) { break }
        }
        return "\(source(ref.source)?.label ?? "guide")/\(ref.id)"
    }

    func choice(for link: StreamLink) -> Choice {
        guard let hash = link.stream?.hash.lowercased(), let value = choices[hash] else {
            return .automatic
        }
        if value.isEmpty { return .none }
        return decodeChoice(value).map(Choice.channel) ?? .automatic
    }

    private func decodeChoice(_ value: String) -> GuideRef? {
        guard !value.isEmpty else { return nil }
        if value.count > 37, let uuid = UUID(uuidString: String(value.prefix(36))),
           value.dropFirst(36).first == "|" {
            return GuideRef(source: uuid, id: String(value.dropFirst(37)))
        }
        return sources.first.map { GuideRef(source: $0.id, id: value) }
    }

    func setChoice(_ choice: Choice, for link: StreamLink) {
        guard let hash = link.stream?.hash.lowercased() else { return }
        switch choice {
        case .automatic: choices[hash] = nil
        case .none: choices[hash] = ""
        case let .channel(ref):
            choices[hash] = "\(ref.source.uuidString)|\(ref.id)"
            ensureSchedules(for: [ref])
        }
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
    }

    /// Exact matches in every source first, then similar names, both in source order; a
    /// name tagged with a country ("(DE)", "PT | …") looks in that country's guides first.
    private func match(_ name: String) -> GuideRef? {
        if let known = matches[name] { return known }
        let hint = Self.countryHint(name)
        // The country's guides first, and none of another country ("Extreme Sports (PL)"
        // isn't the German one).
        let ordered = activeGuides.filter { hint != nil && $0.source.country == hint }
            + activeGuides.filter { hint == nil || $0.source.country == nil }
        var found: GuideRef?
        for (source, guide) in ordered {
            if let id = guide.exactMatch(name, country: hint) {
                found = GuideRef(source: source.id, id: id)
                break
            }
        }
        if found == nil {
            for (source, guide) in ordered {
                if let id = guide.similarMatch(name, country: hint) {
                    found = GuideRef(source: source.id, id: id)
                    break
                }
            }
        }
        matches[name] = found
        return found
    }

    /// Channels in all the guides that could be the one these names mean, most likely
    /// first (earlier sources win ties).
    func suggestions(for names: [String], limit: Int = 12) -> [GuideRef] {
        var scored: [(ref: GuideRef, score: Double, order: Int)] = []
        let automatic = names.lazy.compactMap { self.match($0) }.first
        for (order, (source, guide)) in activeGuides.enumerated() {
            for (id, score) in guide.suggestions(for: names, limit: limit) {
                let ref = GuideRef(source: source.id, id: id)
                scored.append((ref, ref == automatic ? 100 : score, order))
            }
        }
        if let automatic = automatic, !scored.contains(where: { $0.ref == automatic }) {
            scored.append((automatic, 100, 0))
        }
        return scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order
        }.prefix(limit).map(\.ref)
    }

    func search(_ text: String, limit: Int = 60) -> [GuideRef] {
        activeGuides.flatMap { source, guide in
            guide.search(text, limit: limit).map { GuideRef(source: source.id, id: $0) }
        }.prefix(limit).map { $0 }
    }

    func schedule(_ ref: GuideRef, count: Int) -> [Programme] {
        guides[ref.source]?.schedule(ref.id, count: count) ?? []
    }

    func nowShowing(_ ref: GuideRef) -> String? {
        guides[ref.source]?.nowShowing(ref.id)
    }

    /// The source's label, when there is more than one to tell apart.
    func sourceLabel(_ ref: GuideRef) -> String? {
        activeGuides.count > 1 ? source(ref.source)?.label : nil
    }

    /// How many of these links have a guide. Call on the main thread.
    func matchedCount(of links: [StreamLink]) -> Int {
        links.filter { guideChannel(for: $0) != nil }.count
    }

    /// Builds `/epg.xml` for these channels. Call on the main thread; run the result on any.
    func xmlBuilder(for refs: Set<GuideRef>) -> () -> Data {
        let parts = activeGuides.map { source, guide in
            (guide, refs.filter { $0.source == source.id }
                .map { (id: $0.id, served: servedID($0)) })
        }
        return {
            var out = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <tv generator-info-name="AceLinkUI">

            """.utf8)
            for (guide, ids) in parts where !ids.isEmpty {
                guide.appendChannels(ids, to: &out)
            }
            for (guide, ids) in parts where !ids.isEmpty {
                guide.appendProgrammes(ids, to: &out)
            }
            out.append(Data("</tv>\n".utf8))
            return out
        }
    }

    // MARK: - Gzip

    /// The guide is usually published gzipped. Foundation inflates raw deflate (`.zlib`),
    /// so skip the gzip header first. Data that isn't gzipped is returned as is.
    static func gunzipped(_ data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x1F, bytes[1] == 0x8B else { return data }
        let flags = bytes[3]
        var offset = 10
        let all = [UInt8](data)
        if flags & 0x04 != 0, all.count > offset + 2 { // FEXTRA
            offset += 2 + Int(all[offset]) + Int(all[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
            while offset < all.count, all[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < all.count - 8 else { throw GuideError("The guide file is damaged") }
        let deflated = Data(all[offset..<(all.count - 8)])
        do {
            return try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GuideError("Cannot unzip the guide")
        }
    }

    // MARK: - Guide

    struct Programme: Identifiable {
        let title: String
        let subtitle: String?
        let details: String?
        let category: String?
        let start: Date
        let stop: Date

        var id: Date { start }

        var isOn: Bool {
            let now = Date()
            return start <= now && now < stop
        }

        /// How much of it has been shown, 0–1.
        var progress: Double {
            let length = stop.timeIntervalSince(start)
            guard length > 0 else { return 0 }
            return min(max(Date().timeIntervalSince(start) / length, 0), 1)
        }
    }

    /// An XMLTV file indexed by channel: where each `<channel>` and `<programme>` is in the
    /// file, so serving a few channels just copies their bytes. Immutable, so it can be read
    /// from any thread.
    final class Guide: @unchecked Sendable {
        private let data: Data
        /// Channel IDs in file order, with their `<channel>` element.
        private var channels: [(id: String, range: Range<Int>)] = []
        /// Each channel's programmes and when they start and end.
        private var programmes: [String: [(range: Range<Int>, start: Date, stop: Date)]] = [:]
        private var channelIDs: Set<String> = []
        /// Each channel's display names, for searching.
        private var displayNames: [String: [String]] = [:]
        /// Normalized display name → channel ID.
        private var names: [String: String] = [:]
        /// Every channel's keys for similar names and country-tagged ones: their numbers,
        /// letter pairs and the channel's country ("PT" for "PT | DAZN 1").
        private var keys: [(key: String, digits: String, pairs: Set<String>, id: String,
                            country: String?)] = []

        var channelCount: Int { channels.count }

        /// Nil if the data has no channels. `requireProgrammes` leaves out the channels
        /// without any, which a downloaded guide may list; a trimmed copy has none for most.
        init?(data: Data, requireProgrammes: Bool) {
            self.data = data
            index(requireProgrammes: requireProgrammes)
            guard !channels.isEmpty else { return nil }
        }

        private func index(requireProgrammes: Bool) {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                let bytes = buffer.bindMemory(to: UInt8.self)
                var seen: Set<String> = []

                for (range, startTag) in Self.elements("programme", in: bytes) {
                    guard let id = Self.attribute("channel", in: startTag) else { continue }
                    let start = Self.attribute("start", in: startTag).flatMap(Self.date)
                        ?? .distantPast
                    let stop = Self.attribute("stop", in: startTag).flatMap(Self.date)
                        ?? .distantFuture
                    programmes[id, default: []].append((range, start, stop))
                }
                for (range, startTag) in Self.elements("channel", in: bytes) {
                    // Some guides list a channel twice; keep the first.
                    guard let id = Self.attribute("id", in: startTag),
                          !requireProgrammes || programmes[id] != nil,
                          seen.insert(id).inserted else { continue }
                    channels.append((id, range))
                    channelIDs.insert(id)
                    let body = String(decoding: bytes[range], as: UTF8.self)
                    displayNames[id] = Self.texts(of: "display-name", in: body) + [id]
                }

                // Two channels can normalize to the same name: keep the one without a country
                // tag ("DAZN 1 HD" over "PT | DAZN 1"), then the first ("M+ LaLiga HD" over
                // "M+ LaLiga HDR"). Trimmed copies keep the order, so the choice stays.
                // A channel is of a country if any of its names is tagged with it: "FR · beIN
                // SPORTS 1" is French even under its untagged name "beIN SPORTS 1".
                var countries: [String: String] = [:]
                for (id, _) in channels {
                    countries[id] = displayNames[id]?.lazy.compactMap(EPGGuide.countryTag).first
                }
                var tagged: [String: Bool] = [:]
                for (id, _) in channels {
                    for name in displayNames[id] ?? [] {
                        guard let key = EPGGuide.key(name) else { continue }
                        let isTagged = countries[id] != nil
                        if let other = tagged[key], !other || isTagged { continue }
                        names[key] = id
                        tagged[key] = isTagged
                    }
                }
                // Every channel's names, also those that lost to another channel above, so
                // suggestions include "PT | DAZN 2" next to "DAZN 2 HD".
                var added: Set<String> = []
                for (id, _) in channels {
                    for name in displayNames[id] ?? [] {
                        guard let key = EPGGuide.key(name), added.insert("\(key)|\(id)").inserted
                        else { continue }
                        keys.append((key, EPGGuide.digits(of: key), EPGGuide.pairs(of: key), id,
                                     countries[id]))
                    }
                }
            }
        }

        /// The channel with the same normalized name; for a name tagged with a country, the
        /// one tagged with it if there is one ("PT | DAZN 1" for "DAZN 1 (PT)").
        func exactMatch(_ name: String, country: String? = nil) -> String? {
            guard let key = EPGGuide.key(name) else { return nil }
            guard let country = country else { return names[key] }
            let same = keys.filter { $0.key == key }
            if let tagged = same.first(where: { $0.country == country }) { return tagged.id }
            // Not one tagged with another country ("FR · beIN SPORTS 1" for a Turkish one).
            return same.first { $0.country == nil }?.id
        }

        /// The most similar name with the same numbers ("M+ LaLiga 2" never matches
        /// "M+ LaLiga 3"), and not of another country than the name's.
        func similarMatch(_ name: String, country: String? = nil) -> String? {
            guard let key = EPGGuide.key(name) else { return nil }
            let digits = EPGGuide.digits(of: key)
            let pairs = EPGGuide.pairs(of: key)
            guard !pairs.isEmpty else { return nil }
            var best: (score: Double, id: String)?
            for candidate in keys where candidate.digits == digits
                && (country == nil || candidate.country == nil || candidate.country == country) {
                let common = candidate.pairs.intersection(pairs).count
                let score = 2 * Double(common) / Double(candidate.pairs.count + pairs.count)
                if score >= 0.85, score > best?.score ?? 0 { best = (score, candidate.id) }
            }
            return best?.id
        }

        /// Channels that could be the one these names mean, with how likely: exact matches,
        /// then by similarity, with the same numbers counting extra. Each name counts less
        /// than the one before it (the link's name, then the channel's).
        func suggestions(for names: [String], limit: Int = 12) -> [(id: String, score: Double)] {
            var scores: [String: Double] = [:]
            for (index, name) in names.enumerated() {
                let weight = pow(0.7, Double(index))
                if let id = exactMatch(name) { scores[id] = max(scores[id] ?? 0, 10 * weight) }
                guard let key = EPGGuide.key(name) else { continue }
                let digits = EPGGuide.digits(of: key)
                let pairs = EPGGuide.pairs(of: key)
                for candidate in keys {
                    let common = candidate.pairs.intersection(pairs).count
                    var score = pairs.isEmpty ? 0
                        : 2 * Double(common) / Double(candidate.pairs.count + pairs.count)
                    if candidate.key.contains(key) || key.contains(candidate.key) { score += 0.2 }
                    if candidate.digits == digits { score += 0.15 }
                    score *= weight
                    if score > scores[candidate.id] ?? 0.35 { scores[candidate.id] = score }
                }
            }
            return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit).map { ($0.key, $0.value) }
        }

        /// Guide channels whose ID or a display name contains the text.
        func search(_ text: String, limit: Int = 60) -> [String] {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let query = text.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return [] }
            return channels.lazy.map(\.id).filter { id in
                ([id] + (self.displayNames[id] ?? [])).contains {
                    $0.range(of: query, options: options) != nil
                }
            }.prefix(limit).map { $0 }
        }

        func contains(_ id: String) -> Bool { channelIDs.contains(id) }

        /// Whether the whole schedule was kept, not just the next few hours (see `trimmed`).
        func hasFullSchedule(_ id: String) -> Bool {
            guard contains(id) else { return true }
            let last = programmes[id]?.map(\.stop).max() ?? .distantPast
            return last > Date().addingTimeInterval(EPGGuide.previewHours + 3600)
        }

        /// The title of what the channel shows now.
        func nowShowing(_ id: String) -> String? {
            schedule(id, count: 1).first { $0.isOn }?.title
        }

        /// What the channel shows now (if anything) and next, in order.
        func schedule(_ id: String, count: Int) -> [Programme] {
            let now = Date()
            return (programmes[id] ?? []).filter { $0.stop > now }
                .sorted { $0.start < $1.start }
                .prefix(count)
                .map { programme in
                    let text = String(decoding: data[programme.range], as: UTF8.self)
                    // Some guides start texts with "· " or end the sub-title with " |".
                    let junk = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "·|"))
                    let first = { (name: String) in
                        Self.texts(of: name, in: text).first
                            .map { $0.trimmingCharacters(in: junk) }
                            .flatMap { $0.isEmpty ? nil : $0 }
                    }
                    return Programme(
                        title: first("title") ?? "Untitled",
                        subtitle: first("sub-title"),
                        details: first("desc"),
                        category: first("category"),
                        start: programme.start,
                        stop: programme.stop
                    )
                }
        }

        /// The guide to keep on disk: every channel, the whole schedule of these, and of
        /// the rest only what's on in the next hours. Programmes that ended are left out.
        func trimmed(keeping ids: Set<String>, previewHours: TimeInterval) -> Data {
            var out = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <tv generator-info-name="AceLinkUI">

            """.utf8)
            let now = Date()
            let previewEnd = now.addingTimeInterval(previewHours * 3600)
            for (_, range) in channels {
                out.append(data[range])
                out.append(0x0A)
            }
            for (id, _) in channels {
                let full = ids.contains(id)
                for programme in programmes[id] ?? []
                    where programme.stop > now && (full || programme.start < previewEnd) {
                    out.append(data[programme.range])
                    out.append(0x0A)
                }
            }
            out.append(Data("</tv>\n".utf8))
            return out
        }

        /// These channels' `<channel>` elements for `/epg.xml`, with the ID they're served
        /// with (see `EPGGuide.servedID`).
        func appendChannels(_ ids: [(id: String, served: String)], to out: inout Data) {
            let served = Dictionary(ids, uniquingKeysWith: { first, _ in first })
            for (id, range) in channels {
                guard let newID = served[id] else { continue }
                append(range, renaming: "id", from: id, to: newID, to: &out)
            }
        }

        /// These channels' programmes that haven't ended.
        func appendProgrammes(_ ids: [(id: String, served: String)], to out: inout Data) {
            let served = Dictionary(ids, uniquingKeysWith: { first, _ in first })
            let now = Date()
            for (id, _) in channels {
                guard let newID = served[id] else { continue }
                for programme in programmes[id] ?? [] where programme.stop > now {
                    append(programme.range, renaming: "channel", from: id, to: newID, to: &out)
                }
            }
        }

        /// Copies an element, with another value for one attribute of its start tag.
        private func append(_ range: Range<Int>, renaming attribute: String, from id: String,
                            to newID: String, to out: inout Data) {
            defer { out.append(0x0A) }
            guard newID != id, let tagEnd = data[range].firstIndex(of: 0x3E) else {
                return out.append(data[range])
            }
            let tag = String(decoding: data[range.lowerBound...tagEnd], as: UTF8.self)
            let renamed = tag.replacingOccurrences(
                of: #"(\s\#(attribute)=)("[^"]*"|'[^']*')"#,
                with: "$1\"\(NSRegularExpression.escapedTemplate(for: Self.escaped(newID)))\"",
                options: .regularExpression
            )
            out.append(Data(renamed.utf8))
            out.append(data[(tagEnd + 1)..<range.upperBound])
        }

        private static func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        // MARK: Reading the file

        /// Every `<name …>…</name>` (or `<name …/>`) in the file, with its start tag.
        private static func elements(
            _ name: String, in bytes: UnsafeBufferPointer<UInt8>
        ) -> [(Range<Int>, String)] {
            let open = Array("<\(name)".utf8)
            let close = Array("</\(name)>".utf8)
            var found: [(Range<Int>, String)] = []
            var position = 0
            while let start = find(open, in: bytes, from: position) {
                let after = start + open.count
                position = after
                // "<channel" must not be the start of a longer tag name.
                guard after < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x3E, 0x2F]
                    .contains(bytes[after]) else { continue }
                guard let tagEnd = find([0x3E], in: bytes, from: after) else { break }
                let startTag = String(decoding: bytes[start...tagEnd], as: UTF8.self)
                let end: Int
                if bytes[tagEnd - 1] == 0x2F { // Self-closing.
                    end = tagEnd + 1
                } else {
                    guard let closeStart = find(close, in: bytes, from: tagEnd) else { break }
                    end = closeStart + close.count
                }
                found.append((start..<end, startTag))
                position = end
            }
            return found
        }

        private static func find(
            _ pattern: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from start: Int
        ) -> Int? {
            guard let base = bytes.baseAddress, start < bytes.count else { return nil }
            return pattern.withUnsafeBytes { needle -> Int? in
                guard let match = memmem(base + start, bytes.count - start,
                                         needle.baseAddress, needle.count) else { return nil }
                return base.distance(to: match.assumingMemoryBound(to: UInt8.self))
            }
        }

        /// An attribute's value in a start tag, unescaped.
        static func attribute(_ name: String, in tag: String) -> String? {
            for quote in ["\"", "'"] {
                for separator in [" ", "\t", "\n", "\r"] {
                    guard let start = tag.range(of: "\(separator)\(name)=\(quote)") else {
                        continue
                    }
                    let rest = tag[start.upperBound...]
                    guard let end = rest.firstIndex(of: Character(quote)) else { return nil }
                    return unescaped(String(rest[..<end]))
                }
            }
            return nil
        }

        /// The text of every `<name>…</name>` in an element, unescaped.
        private static func texts(of name: String, in element: String) -> [String] {
            var texts: [String] = []
            var rest = element[...]
            while let open = rest.range(of: "<\(name)"),
                  let tagEnd = rest[open.upperBound...].firstIndex(of: ">"),
                  let close = rest[tagEnd...].range(of: "</\(name)>") {
                let text = rest[rest.index(after: tagEnd)..<close.lowerBound]
                texts.append(unescaped(String(text)).trimmingCharacters(in: .whitespaces))
                rest = rest[close.upperBound...]
            }
            return texts
        }

        private static func unescaped(_ text: String) -> String {
            guard text.contains("&") else { return text }
            return text.replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }

        /// XMLTV times: "20261112103500 +0100" (the offset is optional, UTC without it).
        static func date(_ text: String) -> Date? {
            let parts = text.split(separator: " ")
            let digits = Array(parts.first ?? "")
            guard digits.count >= 12, digits.allSatisfy(\.isNumber) else { return nil }
            func number(_ from: Int, _ count: Int) -> Int? {
                from + count <= digits.count ? Int(String(digits[from..<from + count])) : nil
            }
            var components = DateComponents()
            components.year = number(0, 4)
            components.month = number(4, 2)
            components.day = number(6, 2)
            components.hour = number(8, 2)
            components.minute = number(10, 2)
            components.second = number(12, 2) ?? 0
            var offset = 0
            if parts.count > 1, let zone = Int(parts[1]) {
                offset = (zone / 100 * 60 + zone % 100) * 60
            }
            components.timeZone = TimeZone(secondsFromGMT: offset)
            return Calendar(identifier: .gregorian).date(from: components)
        }
    }

    // MARK: - Normalizing names

    /// Words that say how a stream is encoded, not which channel it is.
    private static let qualityWords: Set<String> = [
        "sd", "hd", "fhd", "uhd", "hdr", "4k", "8k", "1080", "1080p", "1080i", "720", "720p",
        "576p", "480p", "25fps", "50fps", "60fps", "hevc", "h264", "h265", "x264", "x265",
        "aac", "ac3", "multi", "multiaudio", "backup", "alt", "sdp", "hdp", "fhdp", "uhdp"
    ]

    /// "ES: …", "|ES| …", "PT · …" before a name.
    private static let countryTag = #"^\s*\|?\s*[a-z]{2}\s*[|:·]\s*"#

    /// The country a guide's channel name starts with: "PT" for "PT | DAZN 1".
    static func countryTag(of name: String) -> String? {
        let lower = name.lowercased()
        guard let range = lower.range(of: countryTag, options: .regularExpression) else {
            return nil
        }
        return lower[range].filter(\.isLetter).uppercased()
    }

    /// Two-letter codes in brackets that aren't countries.
    private static let notCountries: Set<String> = ["HD", "SD", "TV", "FM", "VO", "SE"]

    /// The country a link's name is tagged with: "DE" for "Sky Sport 1 HD (DE)", "UK" for
    /// "BT Sport 1 [UK]", "PT" for "PT: DAZN 1".
    static func countryHint(_ name: String) -> String? {
        let text = name.replacingOccurrences(of: #"-+>.*$"#, with: "", options: .regularExpression)
        if let tag = countryTag(of: text) { return tag }
        let pattern = #"[\[(]\s*([A-Za-z]{2})\s*[\])]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let code = Range(match.range(at: 1), in: text) else { continue }
            let country = text[code].uppercased()
            if !notCountries.contains(country) { return country == "GB" ? "UK" : country }
        }
        return nil
    }

    /// A channel name reduced to what identifies it: lowercase, no accents, no quality
    /// words, bracketed notes, country tags or the source after "-->", "Movistar+" written "m+", and no spaces
    /// ("La Liga" = "LaLiga"). Nil if nothing identifying is left ("1080p", "2").
    static func key(_ name: String) -> String? {
        var text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let replacements: [(String, String)] = [
            (#"-+>.*$"#, " "), // "DAZN 1 --> ELCANO": the list it came from
            (#"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}"#, " "), // [ES], (1080p), {backup}
            (countryTag, " "),
            (#"\bmovistar\s*(\+|plus\b)?"#, " m+ "), // Movistar, Movistar+, Movistar Plus
            (#"\bm\s*\.\s*"#, " m+ "), // "M. LaLiga"
            (#"&"#, " "),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: .regularExpression)
        }
        var words = text.components(separatedBy: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789+").inverted)
            .filter { !$0.isEmpty && $0 != "+" && !qualityWords.contains($0) }
        // "La 1.TV", "Real Madrid TV": a trailing "tv" is part of the name only sometimes.
        if words.count > 1, words.last == "tv" { words.removeLast() }
        let key = words.joined()
        guard !key.isEmpty, !key.allSatisfy(\.isNumber) else { return nil }
        return key
    }

    static func digits(of key: String) -> String {
        key.split { !$0.isNumber }.joined(separator: ",")
    }

    static func pairs(of key: String) -> Set<String> {
        let characters = Array(key)
        guard characters.count > 1 else { return [] }
        return Set((0..<characters.count - 1).map { String(characters[$0...$0 + 1]) })
    }
}
