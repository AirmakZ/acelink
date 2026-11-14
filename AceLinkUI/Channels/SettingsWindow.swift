import Cocoa
import SwiftUI

/// The pages of the Settings window, in the order of its sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case shareToTV, remoteList, tvGuide, liveToday, myGroups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shareToTV: return "Share to TV"
        case .remoteList: return "Remote List"
        case .tvGuide: return "TV Guide"
        case .liveToday: return "Live Today"
        case .myGroups: return "My Groups"
        }
    }

    var symbol: String {
        switch self {
        case .shareToTV: return "tv"
        case .remoteList: return "globe"
        case .tvGuide: return "list.bullet.rectangle"
        case .liveToday: return "calendar"
        case .myGroups: return "square.and.arrow.up.on.square"
        }
    }
}

/// The Settings window's state, shared with the channels window.
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published var pane: SettingsPane? = SettingsPane(
        rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? ""
    ) ?? .shareToTV {
        didSet { UserDefaults.standard.set(pane?.rawValue, forKey: "settingsPane") }
    }

    /// The first group of the last import, for the channels window to show.
    @Published var importedChannelID: UUID?
}

/// Settings in the standard Mac layout: the pages in a sidebar, the chosen one on the right.
struct SettingsView: View {
    @ObservedObject var model = SettingsModel.shared
    @ObservedObject var tv = TVShare.shared
    let onToggleTV: (Bool) -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.pane?.title ?? "").font(.title2.bold())
                    page
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(NoSidebarToggle())
    }

    @ViewBuilder
    private var page: some View {
        switch model.pane {
        case .shareToTV?: TVSharePanel(tv: tv, onToggle: onToggleTV)
        case let pane?: SettingsPanel(pane: pane)
        case nil: EmptyView()
        }
    }
}

/// The sidebar always shows: there are only a few pages.
private struct NoSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init(onToggleTV: @escaping (Bool) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = NSHostingController(
            rootView: SettingsView(onToggleTV: onToggleTV)
        )
        window.setContentSize(NSSize(width: 760, height: 560))
        window.contentMinSize = NSSize(width: 640, height: 440)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    /// Shows the window, on `pane` if given, else on the page last shown.
    func show(_ pane: SettingsPane? = nil) {
        if let pane = pane { SettingsModel.shared.pane = pane }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Exporting your groups to a file and importing them from one.
enum ChannelBackup {
    private static var downloads: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Saves your channels to a file of your choice.
    static func export() {
        let panel = NSSavePanel()
        // Otherwise it opens wherever the last panel was (even /Applications).
        panel.directoryURL = downloads
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AceLinkUI Channels.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ChannelStore.shared.exportData().write(to: url, options: .atomic)
            } catch {
                NSAlert.error("Could not export the groups: \(error.localizedDescription)")
            }
        }
    }

    /// Reads a file of channels and adds them to yours or replaces yours, as you choose.
    /// The channels window then shows the first imported group.
    static func importFile() {
        let panel = NSOpenPanel()
        // Where an exported file, or one sent from another Mac, usually is.
        panel.directoryURL = downloads
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let backup: ChannelStore.Backup
            do {
                backup = try ChannelStore.readBackup(Data(contentsOf: url))
            } catch {
                NSAlert.warning(
                    messageText: "Can't import this file",
                    informativeText: "It isn't a list of groups exported from AceLinkUI."
                )
                return
            }
            guard !backup.channels.isEmpty else {
                NSAlert.warning(messageText: "Nothing to import",
                                informativeText: "The file has no groups.")
                return
            }
            guard let replacing = askHowToImport(backup) else { return }
            let imported = ChannelStore.shared.importBackup(backup, replacing: replacing)
            SettingsModel.shared.importedChannelID = imported.first?.id
        }
    }

    /// Add or replace; nil if cancelled. Doesn't ask when there's nothing to replace.
    private static func askHowToImport(_ backup: ChannelStore.Backup) -> Bool? {
        let store = ChannelStore.shared
        if store.channels.isEmpty { return false }
        let count = backup.channels.count
        let current = store.channels.count
        let alert = NSAlert()
        alert.messageText = "Import \(count) group\(count == 1 ? "" : "s")?"
        alert.informativeText = "Add them after your \(current) group\(current == 1 ? "" : "s"), " +
            "or replace yours with them. Replacing can't be undone."
        alert.addButton(withTitle: "Add")
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn: return true
        default: return nil
        }
    }
}
