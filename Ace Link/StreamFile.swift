import Cocoa
import Foundation
import os

private struct GetStreamInfoResponse: Decodable {
    let response: StreamInfoResponse
    let error: String?
}

private struct StreamInfoResponse: Decodable {
    let statURLString: String
    enum CodingKeys: String, CodingKey {
        case statURLString = "stat_url"
    }
}

struct StreamFile {
    var hash: String
    var type: AppConstants.StreamType
    var title: String = "Unknown stream"
    /// Which Mac player this is for. Each stream playing at the same time gets its own
    /// slot, so it gets its own engine session and playlist file.
    var slot = 0
    /// The engine's stats for this stream's session, once it has started.
    var statURL: URL?

    var playlistFileName: String {
        slot == 0 ? "acelink.m3u8" : "acelink-\(slot).m3u8"
    }

    var playlistURL: URL {
        URL(string: "http://127.0.0.1:\(AppConstants.Docker.proxyPort)/\(playlistFileName)")!
    }

    var param: String {
        switch type {
        case AppConstants.StreamType.magnet:
            return "infohash"
        default:
            return "id"
        }
    }

    var streamURL: URL {
        AppConstants.Docker.baseURL
            .appendingPathComponent("/ace/getstream")
            .appendingQuery(param, hash)
            // A player id keeps this session separate from the TV's (see TVShare) and
            // from other streams playing on the Mac at the same time.
            .appendingQuery("pid", slot == 0 ? "acelink-mac" : "acelink-mac-\(slot)")
    }

    var m3uData: String {
        "#EXTM3U\n#EXTINF:0, Ace Link - \(title)\n\(streamURL.absoluteString)"
    }

    func addToHistory() {
        // Engine titles can contain URLs; slashes would break the file name.
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let file = AppConfig.streamsDir.appendingPathComponent("\(safeTitle).m3u8")
        os_log("Writing data file to %{public}s to maintain history.", file.path)
        do {
            try m3uData.write(to: file, atomically: false, encoding: .utf8)
        } catch {
            os_log("Writing data file failed.")
        }
    }

    /// Calls back with the session's stats URL once the stream has peers.
    func waitForPeers(callback: @escaping (AppError?, URL?) -> Void) {
        getStreamInfo { streamInfo in
            guard let streamInfo = streamInfo,
                  let statURL = URL(string: streamInfo.response.statURLString) else {
                DispatchQueue.main.async {
                    callback(AppError("Cannot get stream info. The link may be offline."), nil)
                }
                return
            }
            StreamPeers(statURL: statURL).task { result in
                callback(result, statURL)
            }
        }
    }

    func getURLForBundleType(_ bundle: Bundle) -> URL {
        if bundle.isBrowser {
            return AppConstants.Docker.baseURL.appendingPathComponent("/webui/player/\(hash)")
        } else {
            return playlistURL
        }
    }

    private func getStreamInfo(callback: @escaping (GetStreamInfoResponse?) -> Void) {
        os_log("Getting stream session urls…")
        let urlSession = URLSession(configuration: .ephemeral)
        let url = streamURL.appendingQuery("format", "json")
        urlSession.jsonDataTask(with: url, decodable: GetStreamInfoResponse.self) { streamInfo in
            callback(streamInfo)
        }.resume()
    }
}
