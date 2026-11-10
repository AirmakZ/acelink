import Foundation

public enum AppConstants {
    static var version: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "0.0.0"
    }

    enum Scheme: String, CaseIterable {
        case magnet
        case acestream
    }

    enum StreamType {
        case acestream
        case magnet
        case none
    }

    enum Docker {
        static let baseURL = URL(string: "http://127.0.0.1:\(enginePort)")!
        static let bundleID = "com.docker.docker"
        static let containerName = "acelinkui-engine"
        /// The container Ace Link (the project this one comes from) used; removed before ours starts.
        static let legacyContainerName = "acelink--ace-stream-server"
        static let enginePort = 6878
        /// The AceStream version in the engine image, which is also its tag. Must match
        /// ACESTREAM_VERSION in the Dockerfile.
        static let engineVersion = "3.2.11"
        static let image = "ghcr.io/airmakz/acelinkui:\(engineVersion)"
        static let proxyPort = 6888
    }
}
