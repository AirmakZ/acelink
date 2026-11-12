import Foundation
import os

/// The TV guide sent with "Share to TV": an XMLTV file downloaded from a URL (by default
/// EPG dobleM, which covers Spanish TV and Movistar+/DAZN), matched to the channels by name.
/// The TV playlist points to `/epg.xml` (`url-tvg`) and gives each entry the `tvg-id` of its
/// match; `/epg.xml` serves only the matched channels, since the whole guide is ~100 MB.
/// A copy is kept on disk so the guide is there at launch and when the download fails.
final class EPGGuide: ObservableObject {
    static let shared = EPGGuide()

    static let path = "/epg.xml"
    static let defaultURL =
        "https://raw.githubusercontent.com/davidmuma/EPG_dobleM/master/guiatv.xml.gz"
    /// How often the guide is downloaded again while the app runs.
    private static let updateEvery: TimeInterval = 12 * 60 * 60

    enum State: Equatable {
        case idle
        case loading
        case updated(Date)
        case failed(String)
    }

    private static let enabledKey = "epgEnabled"
    private static let urlKey = "epgURL"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var urlString = UserDefaults.standard.string(forKey: urlKey)
        ?? defaultURL
    @Published private(set) var state = State.idle
    /// The loaded guide; nil until the copy on disk or a download is read.
    @Published private(set) var guide: Guide?

    var url: URL? { RemoteList.validURL(urlString) }

    var failure: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    /// Names already matched (or not: nil), by name. Main thread only.
    private var matches: [String: String?] = [:]
    private var updateTimer: Timer?

    private static var cacheURL: URL { ChannelStore.baseDir.appendingPathComponent("epg.xml") }

    /// Call on the main thread: the update timer runs on the main run loop.
    private init() {
        guard isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            updateTimer?.invalidate()
            updateTimer = nil
            guide = nil
            matches = [:]
            state = .idle
        }
    }

    /// Saves the address and downloads the guide from it. Empty goes back to the default.
    func setURL(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = trimmed.isEmpty ? Self.defaultURL : trimmed
        UserDefaults.standard.set(urlString, forKey: Self.urlKey)
        state = .idle
        refresh()
        scheduleUpdates()
    }

    /// Reads the copy on disk, then downloads a new one if it's older than `updateEvery`.
    private func start() {
        scheduleUpdates()
        guard guide == nil else { return }
        let cache = Self.cacheURL
        DispatchQueue.global(qos: .utility).async {
            let modified = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let loaded = (try? Data(contentsOf: cache, options: .alwaysMapped))
                .flatMap { Guide(data: $0) }
            DispatchQueue.main.async {
                guard self.isEnabled else { return }
                if let loaded = loaded, self.guide == nil { self.use(loaded) }
                if loaded == nil || Date().timeIntervalSince(modified ?? .distantPast)
                    > Self.updateEvery {
                    self.refresh()
                } else if let modified = modified {
                    self.state = .updated(modified)
                }
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

    private func use(_ guide: Guide) {
        self.guide = guide
        matches = [:]
    }

    func refresh() {
        guard isEnabled, state != .loading, let url = url else { return }
        state = .loading
        Task { @MainActor in
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 60
                let (download, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw GuideError("The server answered \(http.statusCode)")
                }
                // Unzipping and indexing take a moment: keep them off the main thread.
                let (data, guide) = try await Task.detached(priority: .utility) {
                    let data = try Self.gunzipped(download)
                    guard let guide = Guide(data: data) else {
                        throw GuideError("The file is not an XMLTV guide")
                    }
                    return (data, guide)
                }.value
                // Turned off or the address changed while downloading.
                guard isEnabled, url == self.url else { return }
                // Save the copy, and read the guide from it so the ~100 MB aren't kept in
                // memory: a mapped file is paged in only when a TV asks for the guide.
                let cache = Self.cacheURL
                let saved = await Task.detached(priority: .utility) { () -> Guide in
                    try? FileManager.default.createDirectory(
                        at: ChannelStore.baseDir, withIntermediateDirectories: true
                    )
                    guard (try? data.write(to: cache, options: .atomic)) != nil,
                          let mapped = try? Data(contentsOf: cache, options: .alwaysMapped),
                          mapped == data
                    else { return guide }
                    return guide.backed(by: mapped)
                }.value
                guard isEnabled, url == self.url else { return }
                use(saved)
                state = .updated(Date())
                os_log("TV guide updated: %d channels", saved.channelCount)
            } catch {
                os_log("Cannot update the TV guide: %{public}@", error.localizedDescription)
                if url == self.url { state = .failed(error.localizedDescription) }
            }
        }
    }

    struct GuideError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Matching

    /// The guide channel of a playlist entry: the channel's own guide ID if it has one,
    /// else the first of the link's and the channel's names that matches. Link names go
    /// first because they often name the actual channel ("DAZN 1" in "DAZN"); names like
    /// "1080p" or "Option 2" don't match anything and fall through to the channel's.
    /// Call on the main thread.
    func tvgID(channel: Channel, link: StreamLink) -> String? {
        guard isEnabled, let guide = guide else { return nil }
        if let id = channel.epgID?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return id
        }
        return match(link.name, in: guide) ?? match(channel.name, in: guide)
    }

    /// What a name matches automatically, for the channel editor. Call on the main thread.
    func automaticMatch(for name: String) -> String? {
        guard isEnabled, let guide = guide else { return nil }
        return match(name, in: guide)
    }

    private func match(_ name: String, in guide: Guide) -> String? {
        if let known = matches[name] { return known }
        let found = guide.match(name)
        matches[name] = found
        return found
    }

    /// How many of these channels have a guide. Call on the main thread.
    func matchedCount(of channels: [Channel]) -> Int {
        channels.filter { channel in
            channel.links.contains { tvgID(channel: channel, link: $0) != nil }
        }.count
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

    /// An XMLTV file indexed by channel: where each `<channel>` and `<programme>` is in the
    /// file, so serving a few channels just copies their bytes. Immutable, so it can be read
    /// from any thread; `match` is the only work done per name.
    final class Guide: @unchecked Sendable {
        private let data: Data
        /// Channel IDs in file order, with their `<channel>` element.
        private var channels: [(id: String, range: Range<Int>)] = []
        /// Each channel's programmes and when they end.
        private var programmes: [String: [(range: Range<Int>, stop: Date)]] = [:]
        /// Normalized display name → channel ID.
        private var names: [String: String] = [:]
        /// The same keys for fuzzy matching: their numbers and letter pairs.
        private var keys: [(key: String, digits: String, pairs: Set<String>, id: String)] = []

        var channelCount: Int { channels.count }

        /// Nil if the data has no channel with programmes.
        init?(data: Data) {
            self.data = data
            index()
            guard !channels.isEmpty else { return nil }
        }

        private init(data: Data, copying other: Guide) {
            self.data = data
            channels = other.channels
            programmes = other.programmes
            names = other.names
            keys = other.keys
        }

        /// The same guide read from another copy of the same bytes.
        func backed(by data: Data) -> Guide {
            Guide(data: data, copying: self)
        }

        private func index() {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                let bytes = buffer.bindMemory(to: UInt8.self)
                var displayNames: [String: [String]] = [:]
                var seen: Set<String> = []

                for (range, startTag) in Self.elements("programme", in: bytes) {
                    guard let id = Self.attribute("channel", in: startTag) else { continue }
                    let stop = Self.attribute("stop", in: startTag).flatMap(Self.date)
                        ?? .distantFuture
                    programmes[id, default: []].append((range, stop))
                }
                for (range, startTag) in Self.elements("channel", in: bytes) {
                    // Some guides list a channel twice; keep the first.
                    guard let id = Self.attribute("id", in: startTag), programmes[id] != nil,
                          seen.insert(id).inserted else { continue }
                    channels.append((id, range))
                    let body = String(decoding: bytes[range], as: UTF8.self)
                    displayNames[id] = Self.texts(of: "display-name", in: body) + [id]
                }

                // Two channels can normalize to the same name: keep the one without a country
                // tag ("DAZN 1 HD" over "PT | DAZN 1"), then the one with more programmes
                // ("M+ LaLiga HD" over "M+ LaLiga HDR").
                var rank: [String: (tagged: Bool, count: Int)] = [:]
                for (id, _) in channels {
                    let count = programmes[id]?.count ?? 0
                    for name in displayNames[id] ?? [] {
                        guard let key = EPGGuide.key(name) else { continue }
                        let tagged = EPGGuide.hasCountryTag(name)
                        if let other = rank[key],
                           other.tagged != tagged ? tagged : other.count >= count {
                            continue
                        }
                        names[key] = id
                        rank[key] = (tagged, count)
                    }
                }
                keys = names.map { key, id in
                    (key, EPGGuide.digits(of: key), EPGGuide.pairs(of: key), id)
                }
            }
        }

        /// The channel a name matches: the same normalized name, else the most similar one
        /// with the same numbers ("M+ LaLiga 2" never matches "M+ LaLiga 3").
        func match(_ name: String) -> String? {
            guard let key = EPGGuide.key(name) else { return nil }
            if let id = names[key] { return id }
            let digits = EPGGuide.digits(of: key)
            let pairs = EPGGuide.pairs(of: key)
            guard !pairs.isEmpty else { return nil }
            var best: (score: Double, id: String)?
            for candidate in keys where candidate.digits == digits {
                let common = candidate.pairs.intersection(pairs).count
                let score = 2 * Double(common) / Double(candidate.pairs.count + pairs.count)
                if score >= 0.85, score > best?.score ?? 0 { best = (score, candidate.id) }
            }
            return best?.id
        }

        /// An XMLTV file with just these channels and the programmes that haven't ended.
        func xml(for ids: Set<String>) -> Data {
            var out = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <tv generator-info-name="AceLinkUI">

            """.utf8)
            let now = Date()
            for (id, range) in channels where ids.contains(id) {
                out.append(data[range])
                out.append(0x0A)
            }
            for (id, _) in channels where ids.contains(id) {
                for programme in programmes[id] ?? [] where programme.stop > now {
                    out.append(data[programme.range])
                    out.append(0x0A)
                }
            }
            out.append(Data("</tv>\n".utf8))
            return out
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
        "aac", "ac3", "multi", "multiaudio", "backup", "alt"
    ]

    /// "ES: …", "|ES| …", "PT · …" before a name.
    private static let countryTag = #"^\s*\|?\s*[a-z]{2}\s*[|:·]\s*"#

    static func hasCountryTag(_ name: String) -> Bool {
        name.lowercased().range(of: countryTag, options: .regularExpression) != nil
    }

    /// A channel name reduced to what identifies it: lowercase, no accents, no quality
    /// words, bracketed notes or country tags, "Movistar+" written "m+", and no spaces
    /// ("La Liga" = "LaLiga"). Nil if nothing identifying is left ("1080p", "2").
    static func key(_ name: String) -> String? {
        var text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let replacements: [(String, String)] = [
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
