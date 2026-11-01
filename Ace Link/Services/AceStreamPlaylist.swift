import Foundation
import os

private struct GetPlaylistResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let playlist: [Playlist]
    }

    struct Playlist: Decodable {
        let title: String
        let contentID: String?
        let infohash: String?

        enum CodingKeys: String, CodingKey {
            case title
            case contentID = "content_id"
            case infohash
        }
    }
}

/// Adds the stream to the engine's playlist to learn its title.
class AceStreamPlaylist: Service {
    let aceStreamEngine: AceStreamEngine
    let stream: StreamFile
    var title: String?

    /// The add request is resent this often until the stream shows up, because the
    /// engine can drop requests while it is still starting (slow under emulation).
    private let resendAddEvery: TimeInterval = 3
    private var lastAdd = Date.distantPast

    override var maxWait: DispatchTimeInterval { DispatchTimeInterval.seconds(20) }
    override var defaultError: String { "Cannot get stream title." }

    init(aceStreamEngine: AceStreamEngine, stream: StreamFile) {
        self.aceStreamEngine = aceStreamEngine
        self.stream = stream
        super.init()
        os_log("Getting stream title for %s=%s…", stream.param, stream.hash)
    }

    private func addItem() {
        lastAdd = Date()
        let url = AppConstants.Docker.baseURL.appendingPathComponent("/server/api")
            .appendingQuery("method", "playlist_add_item")
            .appendingQuery("token", aceStreamEngine.accessToken!)
            .appendingQuery(stream.param, stream.hash)
        urlSession.dataTask(with: url).resume()
    }

    override func check() {
        if Date().timeIntervalSince(lastAdd) >= resendAddEvery {
            addItem()
        }

        let url = AppConstants.Docker.baseURL.appendingPathComponent("/server/api")
            .appendingQuery("method", "playlist_get")
            .appendingQuery("token", aceStreamEngine.accessToken!)

        urlSession.jsonDataTask(with: url, decodable: GetPlaylistResponse.self) { data in
            let hash = self.stream.hash.lowercased()
            let items = data?.result.playlist ?? []
            // Prefer the item for this stream; the playlist can hold older ones.
            let item = items.first {
                $0.contentID?.lowercased() == hash || $0.infohash?.lowercased() == hash
            } ?? items.first
            if let item = item {
                os_log("Got title: %s", item.title)
                self.title = item.title
                self.callbackInMainThread()
                return
            }
            self.scheduleCheck()
        }.resume()
    }
}
