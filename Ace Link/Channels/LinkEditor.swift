import SwiftUI

final class LinkDraft: ObservableObject {
    @Published var link: StreamLink
    init(link: StreamLink) { self.link = link }
}

struct LinkEditor: View {
    @StateObject private var draft: LinkDraft
    let isNew: Bool
    let onSave: (StreamLink) -> Void
    let onCancel: () -> Void

    init(link: StreamLink, isNew: Bool, onSave: @escaping (StreamLink) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: LinkDraft(link: link))
        self.isNew = isNew
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

    private var isValid: Bool {
        StreamLink(name: "", url: trimmedURL).stream != nil
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
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
