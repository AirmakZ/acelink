import Foundation

/// What the app is doing right now, shown at the bottom of the channels window.
final class PlaybackStatus: ObservableObject {
    static let shared = PlaybackStatus()

    enum State: Equatable {
        case idle
        case working(String)
        case playing(String)
        case failed(String)
    }

    @Published var state: State = .idle
    /// The link that is loading, so the list can show a spinner on it.
    @Published var activeLinkID: UUID?
    /// Links playing on the Mac right now (more than one with "Play Alongside").
    @Published var playingLinkIDs: Set<UUID> = []
    /// What the status bar shows when nothing else is going on.
    var nowPlaying: String?

    /// Clears an error and goes back to showing what's playing.
    func dismiss() {
        set(nowPlaying.map { .playing($0) } ?? .idle)
    }

    var isBusy: Bool {
        if case .working = state { return true }
        return false
    }

    func set(_ state: State) {
        if Thread.isMainThread {
            self.state = state
        } else {
            DispatchQueue.main.async { self.state = state }
        }
    }
}
