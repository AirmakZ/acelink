import Cocoa
import Foundation
import os

/// How a channel is drawn in the sidebar.
enum ChannelIcon: Equatable {
    /// An SF Symbol name with a tint color (hex, e.g. "#FF3B30").
    case symbol(name: String, color: String)
    /// A single emoji.
    case emoji(String)
    /// A PNG stored in the icons directory (file name only).
    case image(fileName: String)

    static let `default` = ChannelIcon.symbol(name: "tv", color: "#0A84FF")
}

/// Saved as `{"symbol": {"name", "color"}}`, `{"emoji": {"text"}}` or
/// `{"image": {"fileName"}}`. The synthesized coding named the emoji "_0"; files
/// written that way still read.
extension ChannelIcon: Codable {
    private enum CodingKeys: String, CodingKey { case symbol, emoji, image }
    private enum ValueKeys: String, CodingKey {
        case name, color, text, fileName
        case legacy = "_0"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "No icon case"
            ))
        }
        let values = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: key)
        switch key {
        case .symbol:
            self = .symbol(
                name: try values.decode(String.self, forKey: .name),
                color: try values.decode(String.self, forKey: .color)
            )
        case .emoji:
            self = .emoji(try values.decodeIfPresent(String.self, forKey: .text)
                ?? values.decode(String.self, forKey: .legacy))
        case .image:
            self = .image(fileName: try values.decode(String.self, forKey: .fileName))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .symbol(name, color):
            var values = container.nestedContainer(keyedBy: ValueKeys.self, forKey: .symbol)
            try values.encode(name, forKey: .name)
            try values.encode(color, forKey: .color)
        case let .emoji(text):
            var values = container.nestedContainer(keyedBy: ValueKeys.self, forKey: .emoji)
            try values.encode(text, forKey: .text)
        case let .image(fileName):
            var values = container.nestedContainer(keyedBy: ValueKeys.self, forKey: .image)
            try values.encode(fileName, forKey: .fileName)
        }
    }
}

struct StreamLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// What the user pasted: a hash, acestream:// link or magnet URI.
    var url: String
    /// The last time the link worked: a check found it green or orange, or it played.
    var lastSeen: Date?
    /// The result of the last availability check, kept across launches so the list can
    /// show the previous state (as a ring) until the link is checked again.
    var lastResult: Availability?
    /// The peers the engine reported in that check, if it could read them.
    var lastPeers: Int?

    var stream: StreamFile? {
        guard let stream = ExtractStream.from(unverifiedData: url), !stream.hash.isEmpty else {
            return nil
        }
        return stream
    }

    var shortHash: String {
        guard let stream = stream else { return "Invalid link" }
        return String(stream.hash.prefix(10))
    }
}

struct Channel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: ChannelIcon = .default
    var links: [StreamLink] = []
}

/// Keeps the channel list in memory and saves it to
/// ~/Library/Application Support/AceLinkUI/channels.json on every change.
final class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    @Published var channels: [Channel] = [] {
        didSet { save() }
    }

    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AceLinkUI")
    }

    static var iconsDir: URL { baseDir.appendingPathComponent("icons") }
    private static var defaultFileURL: URL { baseDir.appendingPathComponent("channels.json") }

    /// Where the channels are saved; nil keeps them in memory only (the remote list).
    private let fileURL: URL?
    private var loading = false

    init(fileURL: URL? = ChannelStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Channels

    func channel(id: UUID?) -> Channel? {
        channels.first { $0.id == id }
    }

    func upsert(_ channel: Channel) {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            let old = channels[index]
            channels[index] = channel
            removeUnusedIconFile(old.icon, replacedBy: channel.icon)
        } else {
            channels.append(channel)
        }
    }

    func delete(channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        let removed = channels.remove(at: index)
        removeUnusedIconFile(removed.icon, replacedBy: nil)
    }

    func moveChannels(from source: IndexSet, to destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Links

    func upsert(link: StreamLink, in channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        if let linkIndex = channels[index].links.firstIndex(where: { $0.id == link.id }) {
            channels[index].links[linkIndex] = link
        } else {
            channels[index].links.append(link)
        }
    }

    func add(links: [StreamLink], to channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].links.append(contentsOf: links)
    }

    /// Puts working links first, then slow ones, and dead ones last, keeping the order within
    /// each group. Links without a result (e.g. added during the check) go before dead ones.
    /// Dead links are ordered by when they last worked, so the longest-dead end up at the bottom.
    func sortLinks(in channelID: UUID, by availability: [UUID: Availability]) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        func key(_ link: StreamLink, _ offset: Int) -> (Int, Double, Int) {
            let rank = availability[link.id]?.rank ?? Availability.checking.rank
            // Most recently seen first; never seen last.
            let age = rank == Availability.unavailable.rank
                ? -(link.lastSeen?.timeIntervalSinceReferenceDate ?? -.infinity) : 0
            return (rank, age, offset)
        }
        let links = channels[index].links
        channels[index].links = links.enumerated()
            .sorted { key($0.element, $0.offset) < key($1.element, $1.offset) }
            .map(\.element)
    }

    /// Records that a stream delivered video now, on every link that points to it.
    func markSeen(hash: String, at date: Date = Date()) {
        updateLinks(hash: hash) { $0.lastSeen = date }
    }

    /// Saves a check result on every link that points to the stream. A working result
    /// (green or orange) also updates "last seen".
    func record(_ result: Availability, peers: Int? = nil, hash: String, at date: Date = Date()) {
        guard !result.isPending else { return }
        updateLinks(hash: hash) { link in
            link.lastResult = result
            link.lastPeers = peers
            if result.rank <= Availability.slow(0).rank { link.lastSeen = date }
        }
    }

    private func updateLinks(hash: String, _ change: (inout StreamLink) -> Void) {
        let hash = hash.lowercased()
        var updated = channels // Edit a copy so the file is saved once.
        for channelIndex in updated.indices {
            for linkIndex in updated[channelIndex].links.indices
                where updated[channelIndex].links[linkIndex].stream?.hash.lowercased() == hash {
                change(&updated[channelIndex].links[linkIndex])
            }
        }
        if updated != channels { channels = updated }
    }

    func delete(linkID: UUID, in channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].links.removeAll { $0.id == linkID }
    }

    func moveLinks(in channelID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].links.move(fromOffsets: source, toOffset: destination)
    }

    /// Moves links (in their current order) from one channel to another, or within the
    /// same channel. `index` is the insertion offset in the destination as shown before the
    /// move; nil appends.
    func move(linkIDs: Set<UUID>, from sourceID: UUID, to destinationID: UUID, at index: Int? = nil) {
        guard let source = channels.firstIndex(where: { $0.id == sourceID }),
              let destination = channels.firstIndex(where: { $0.id == destinationID })
        else { return }
        let moving = channels[source].links.filter { linkIDs.contains($0.id) }
        guard !moving.isEmpty else { return }

        var updated = channels // Edit a copy so the file is saved once.
        var insertAt = index ?? updated[destination].links.count
        if source == destination {
            // Links removed above the insertion point shift it up.
            let before = updated[source].links.prefix(insertAt).filter { linkIDs.contains($0.id) }
            insertAt -= before.count
        }
        updated[source].links.removeAll { linkIDs.contains($0.id) }
        insertAt = min(max(insertAt, 0), updated[destination].links.count)
        updated[destination].links.insert(contentsOf: moving, at: insertAt)
        channels = updated
    }

    // MARK: - Icons

    /// Copies an image into the icons directory as a 256px PNG and returns its file name.
    static func importIcon(from url: URL) -> String? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let side: CGFloat = 256
        let resized = NSImage(size: NSSize(width: side, height: side))
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // Aspect-fill into a square.
        let scale = max(side / image.size.width, side / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: NSRect(
                x: (side - drawSize.width) / 2,
                y: (side - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }

        let fileName = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
            try png.write(to: iconsDir.appendingPathComponent(fileName))
            return fileName
        } catch {
            os_log("Cannot save icon: %{public}@", error.localizedDescription)
            return nil
        }
    }

    static func iconImage(fileName: String) -> NSImage? {
        NSImage(contentsOf: iconsDir.appendingPathComponent(fileName))
    }

    private func removeUnusedIconFile(_ icon: ChannelIcon, replacedBy newIcon: ChannelIcon?) {
        guard case let .image(fileName) = icon, icon != newIcon else { return }
        try? FileManager.default.removeItem(at: Self.iconsDir.appendingPathComponent(fileName))
    }

    // MARK: - Export and import

    /// A file with channels, to keep a copy or move them to another Mac. Custom icons
    /// travel inside it, since they're files of their own here.
    struct Backup: Codable {
        static let formatName = "acelink-channels"
        var format = formatName
        var version = 1
        var channels: [Channel]
        /// PNGs of `.image` icons by file name (base64 in the JSON).
        var icons: [String: Data] = [:]
    }

    func exportData() throws -> Data {
        var icons: [String: Data] = [:]
        for channel in channels {
            if case let .image(fileName) = channel.icon,
               let data = try? Data(contentsOf: Self.iconsDir.appendingPathComponent(fileName)) {
                icons[fileName] = data
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Backup(channels: channels, icons: icons))
    }

    /// Reads an exported file, or a plain channels.json (without its icons).
    static func readBackup(_ data: Data) throws -> Backup {
        if let backup = try? JSONDecoder().decode(Backup.self, from: data),
           backup.format == Backup.formatName {
            return backup
        }
        return Backup(channels: try JSONDecoder().decode([Channel].self, from: data))
    }

    /// Adds the file's channels after the current ones, or replaces them. Returns the
    /// imported channels as stored (added ones get new IDs where they'd clash).
    @discardableResult
    func importBackup(_ backup: Backup, replacing: Bool) -> [Channel] {
        var takenIDs = replacing ? Set<UUID>() : Set(channels.flatMap { [$0.id] + $0.links.map(\.id) })
        func freshID(_ id: UUID) -> UUID {
            let id = takenIDs.contains(id) ? UUID() : id
            takenIDs.insert(id)
            return id
        }
        let imported = backup.channels.map { channel -> Channel in
            var channel = channel
            channel.id = freshID(channel.id)
            channel.links = channel.links.map { link in
                var link = link
                link.id = freshID(link.id)
                return link
            }
            channel.icon = importedIcon(channel.icon, from: backup)
            return channel
        }
        channels = replacing ? imported : channels + imported
        // The icons directory belongs to the saved channels, not the in-memory remote list.
        if replacing, fileURL != nil { removeUnreferencedIconFiles() }
        return imported
    }

    /// Saves a backup's icon under a new file name; the default icon if it isn't there.
    private func importedIcon(_ icon: ChannelIcon, from backup: Backup) -> ChannelIcon {
        guard case let .image(fileName) = icon else { return icon }
        guard let data = backup.icons[fileName] else {
            // A plain channels.json from this Mac still finds its icons.
            let local = Self.iconsDir.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: local.path) ? icon : .default
        }
        let newName = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: Self.iconsDir, withIntermediateDirectories: true)
            try data.write(to: Self.iconsDir.appendingPathComponent(newName))
            return .image(fileName: newName)
        } catch {
            os_log("Cannot save imported icon: %{public}@", error.localizedDescription)
            return .default
        }
    }

    private func removeUnreferencedIconFiles() {
        var used = Set<String>()
        for channel in channels {
            if case let .image(fileName) = channel.icon { used.insert(fileName) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.iconsDir.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: Self.iconsDir.appendingPathComponent(file))
        }
    }

    // MARK: - Persistence

    private func load() {
        loading = true
        defer { loading = false }
        guard let fileURL = fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            channels = try JSONDecoder().decode([Channel].self, from: data)
        } catch {
            os_log("Cannot read channels.json: %{public}@", error.localizedDescription)
        }
    }

    private func save() {
        if loading { return }
        guard let fileURL = fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.baseDir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(channels).write(to: fileURL, options: .atomic)
        } catch {
            os_log("Cannot save channels.json: %{public}@", error.localizedDescription)
        }
    }
}
