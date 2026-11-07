import CryptoKit
import Foundation
import os

/// The remote channel list: an m3u fetched from a URL, grouped into channels by `group-title`.
/// A copy is kept on disk and loaded at start, so the list is there even when the download
/// fails; a failed update is shown in the toolbar.
final class RemoteList: ObservableObject {
    static let shared = RemoteList()

    enum State: Equatable {
        case idle
        case loading
        case updated(Date)
        case failed(String)
    }

    var failure: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    /// TODO: define how the URL is configured (setting, import, …). Hard-coded for now.
    static let url = URL(
        string: "https://tokyo.elcano-ipfs.workers.dev/k51qzi5uqu5dh5qej4b9wlcr5i6vhc7rcfkekhrxqek5c9lk6gdaiik820fecs/hashes_acestream.m3u"
    )

    @Published private(set) var state = State.idle
    /// In memory only: the list is read from the m3u copy, never edited.
    let store = ChannelStore(fileURL: nil)

    private static var cacheURL: URL { ChannelStore.baseDir.appendingPathComponent("remote.m3u") }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let text = String(data: data, encoding: .utf8) {
            store.channels = Self.parse(text)
        }
        refresh()
    }

    func refresh() {
        guard state != .loading, let url = Self.url else { return }
        state = .loading
        Task { @MainActor in
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw RemoteError("The server answered \(http.statusCode)")
                }
                guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
                    throw RemoteError("The file is not an m3u playlist")
                }
                let channels = Self.parse(text)
                guard !channels.isEmpty else { throw RemoteError("The playlist has no links") }
                store.channels = channels
                try? FileManager.default.createDirectory(
                    at: ChannelStore.baseDir, withIntermediateDirectories: true
                )
                try? data.write(to: Self.cacheURL, options: .atomic)
                state = .updated(Date())
            } catch {
                os_log("Cannot update the remote list: %{public}@", error.localizedDescription)
                state = .failed(error.localizedDescription)
            }
        }
    }

    private struct RemoteError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Parsing

    /// Reads `#EXTINF` entries (name after the last comma, `group-title="…"`) followed by their
    /// link. IDs derive from the content, so a refresh keeps the selection.
    static func parse(_ text: String) -> [Channel] {
        var groups: [String: [StreamLink]] = [:]
        var order: [String] = []
        var pending: (name: String, group: String)?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                let name = line.range(of: ",", options: .backwards)
                    .map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                pending = (name, attribute("group-title", in: line) ?? "Ungrouped")
            } else if !line.isEmpty, !line.hasPrefix("#"), let entry = pending {
                pending = nil
                guard let stream = ExtractStream.from(unverifiedData: line), !stream.hash.isEmpty
                else { continue }
                if groups[entry.group] == nil { order.append(entry.group) }
                let index = groups[entry.group]?.count ?? 0
                groups[entry.group, default: []].append(StreamLink(
                    id: stableID("\(entry.group)|\(index)|\(stream.hash)"),
                    name: entry.name.isEmpty ? String(stream.hash.prefix(10)) : entry.name,
                    url: line
                ))
            }
        }
        return order.map { group in
            Channel(
                id: stableID("group|\(group)"), name: group,
                icon: .symbol(name: "globe", color: "#0A84FF"), links: groups[group] ?? []
            )
        }
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    private static func stableID(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                           bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                           bytes[13], bytes[14], bytes[15]))
    }
}
