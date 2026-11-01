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
    /// The link that is loading or playing, so the list can highlight it.
    @Published var activeLinkID: UUID?

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
