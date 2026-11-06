import SwiftUI

final class LinkDraft: ObservableObject {
    @Published var link: StreamLink
    init(link: StreamLink) { self.link = link }
}

struct LinkEditor: View {
    @StateObject private var draft: LinkDraft
    let isNew: Bool
    /// The channel the link belongs to, and all channels, to find duplicates.
    let channelID: UUID
    let channels: [Channel]
    let onSave: (StreamLink) -> Void
    let onCancel: () -> Void
    /// The stream before editing; "last seen" no longer applies if it changes.
    private let originalHash: String?

    init(link: StreamLink, isNew: Bool, channelID: UUID, channels: [Channel],
         onSave: @escaping (StreamLink) -> Void, onCancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: LinkDraft(link: link))
        originalHash = link.stream?.hash.lowercased()
        self.isNew = isNew
        self.channelID = channelID
        self.channels = channels
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// A new link, pre-filled with the clipboard contents when they look like a stream.
    static func draftFromClipboard(defaultName: String = "") -> StreamLink {
        var draft = StreamLink(name: defaultName, url: "")
        if let clip = NSPasteboard.general.string(forType: .string),
           let stream = ExtractStream.from(unverifiedData: clip), !stream.hash.isEmpty {
            draft.url = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return draft
    }

    private var trimmedURL: String {
        draft.link.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hash: String? {
        StreamLink(name: "", url: trimmedURL).stream?.hash.lowercased()
    }

    private var isValid: Bool { hash != nil }

    /// Other links with the same stream. The link being edited is left out, so saving
    /// it unchanged is never reported as a duplicate of itself.
    private var duplicates: (sameChannel: StreamLink?, otherChannels: [String]) {
        guard let hash = hash else { return (nil, []) }
        var sameChannel: StreamLink?
        var otherChannels: [String] = []
        for channel in channels {
            let matches = channel.links.filter {
                $0.id != draft.link.id && $0.stream?.hash.lowercased() == hash
            }
            guard let first = matches.first else { continue }
            if channel.id == channelID {
                sameChannel = first
            } else {
                otherChannels.append(channel.name)
            }
        }
        return (sameChannel, otherChannels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Link" : "Edit Link").font(.headline)

            Form {
                TextField("Name", text: $draft.link.name, prompt: Text("e.g. HD Spanish"))
                TextField(
                    "Link", text: $draft.link.url,
                    prompt: Text("acestream://… or 40-character hash or magnet:")
                )
                .font(.system(.body, design: .monospaced))
            }

            if !trimmedURL.isEmpty, !isValid {
                Label("Not a valid AceStream hash, acestream:// link or magnet URI.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
            }

            let duplicates = self.duplicates
            if let existing = duplicates.sameChannel {
                Label("This channel already has this link"
                    + (existing.name.isEmpty ? "." : " as “\(existing.name)”."),
                    systemImage: "xmark.octagon")
                    .foregroundColor(.red)
                    .font(.caption)
            } else if !duplicates.otherChannels.isEmpty {
                Label("This link is also in "
                    + ListFormatter.localizedString(byJoining: duplicates.otherChannels) + ".",
                    systemImage: "info.circle")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }

            HStack {
                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        draft.link.url = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var saved = draft.link
                    saved.url = trimmedURL
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    if hash != originalHash { saved.lastSeen = nil }
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || duplicates.sameChannel != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
