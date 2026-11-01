import Cocoa
import Foundation
import os

/// How a channel is drawn in the sidebar.
enum ChannelIcon: Codable, Equatable {
    /// An SF Symbol name with a tint color (hex, e.g. "#FF3B30").
    case symbol(name: String, color: String)
    /// A single emoji.
    case emoji(String)
    /// A PNG stored in the icons directory (file name only).
    case image(fileName: String)

    static let `default` = ChannelIcon.symbol(name: "tv", color: "#0A84FF")
}

struct StreamLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// What the user pasted: a hash, acestream:// link or magnet URI.
    var url: String

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
/// ~/Library/Application Support/Ace Link/channels.json on every change.
final class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    @Published var channels: [Channel] = [] {
        didSet { save() }
    }

    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ace Link")
    }

    static var iconsDir: URL { baseDir.appendingPathComponent("icons") }
    private static var fileURL: URL { baseDir.appendingPathComponent("channels.json") }

    private var loading = false

    init() {
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

    func delete(linkID: UUID, in channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].links.removeAll { $0.id == linkID }
    }

    func moveLinks(in channelID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].links.move(fromOffsets: source, toOffset: destination)
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

    // MARK: - Persistence

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            channels = try JSONDecoder().decode([Channel].self, from: data)
        } catch {
            os_log("Cannot read channels.json: %{public}@", error.localizedDescription)
        }
    }

    private func save() {
        if loading { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.baseDir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(channels).write(to: Self.fileURL, options: .atomic)
        } catch {
            os_log("Cannot save channels.json: %{public}@", error.localizedDescription)
        }
    }
}
