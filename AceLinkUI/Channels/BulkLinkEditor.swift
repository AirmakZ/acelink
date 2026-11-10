import SwiftUI

struct BulkAddTarget: Identifiable {
    let id: UUID // channel ID
}

/// Turns pasted text into links. Understands:
/// - one link per line, optionally with a name: "HD Spanish acestream://<hash>"
///   or "acestream://<hash> | HD Spanish" (separators like - | , : are stripped)
/// - M3U playlists: "#EXTINF:-1,Channel name" followed by the link on the next line
enum BulkLinkParser {
    struct Result {
        var links: [StreamLink] = []
        var invalidLines: [String] = []
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(acestream://[0-9a-fA-F]{40}|magnet:\?\S+|\b[0-9a-fA-F]{40}\b)"#
    )
    private static let nameTrim = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "-–—|,;:•*\t\"'()[]"))

    static func parse(_ text: String) -> Result {
        var result = Result()
        var pendingName: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "#EXTM3U" { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                if let comma = line.lastIndex(of: ",") {
                    let name = line[line.index(after: comma)...].trimmingCharacters(in: nameTrim)
                    pendingName = name.isEmpty ? nil : name
                }
                continue
            }
            if line.hasPrefix("#") { continue }

            let range = NSRange(line.startIndex..., in: line)
            guard let match = linkPattern.firstMatch(in: line, range: range),
                  let matchRange = Range(match.range, in: line) else {
                result.invalidLines.append(line)
                continue
            }

            let url = String(line[matchRange])
            var name = line.replacingCharacters(in: matchRange, with: " ")
                .trimmingCharacters(in: nameTrim)
            if name.isEmpty, let pending = pendingName { name = pending }
            pendingName = nil

            let link = StreamLink(name: name, url: url)
            if link.stream != nil {
                result.links.append(link)
            } else {
                result.invalidLines.append(line)
            }
        }
        return result
    }
}

final class BulkDraft: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

struct BulkLinkEditor: View {
    let existingLinks: [StreamLink]
    let onAdd: ([StreamLink]) -> Void
    let onCancel: () -> Void

    @StateObject private var draft: BulkDraft

    init(existingLinks: [StreamLink], onAdd: @escaping ([StreamLink]) -> Void,
         onCancel: @escaping () -> Void) {
        self.existingLinks = existingLinks
        self.onAdd = onAdd
        self.onCancel = onCancel
        // Pre-fill from the clipboard when it contains at least one link.
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        let prefill = BulkLinkParser.parse(clip).links.isEmpty ? "" : clip
        _draft = StateObject(wrappedValue: BulkDraft(text: prefill))
    }

    /// Parsed links, minus duplicates (already in the channel or repeated in the text),
    /// with default names filled in.
    private var preview: (links: [StreamLink], duplicates: Int, invalid: [String]) {
        let parsed = BulkLinkParser.parse(draft.text)
        var seen = Set(existingLinks.compactMap { $0.stream?.hash.lowercased() })
        var links: [StreamLink] = []
        var duplicates = 0
        for var link in parsed.links {
            guard let hash = link.stream?.hash.lowercased(), !seen.contains(hash) else {
                duplicates += 1
                continue
            }
            seen.insert(hash)
            if link.name.isEmpty {
                link.name = "Link \(existingLinks.count + links.count + 1)"
            }
            links.append(link)
        }
        return (links, duplicates, parsed.invalidLines)
    }

    var body: some View {
        let preview = self.preview

        VStack(alignment: .leading, spacing: 12) {
            Text("Add Links in Bulk").font(.headline)
            Text("Paste one link per line. You can put a name on the same line, " +
                "e.g. “HD Spanish acestream://…”. M3U playlists work too.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft.text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            if !preview.links.isEmpty {
                List(preview.links) { link in
                    HStack {
                        Text(link.name)
                        Spacer()
                        Text(link.shortHash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 130)
            }

            HStack(spacing: 12) {
                Label("\(preview.links.count) to add", systemImage: "checkmark.circle")
                    .foregroundColor(preview.links.isEmpty ? .secondary : .green)
                if preview.duplicates > 0 {
                    Label("\(preview.duplicates) duplicate\(preview.duplicates == 1 ? "" : "s") skipped",
                          systemImage: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                if !preview.invalid.isEmpty {
                    Label("\(preview.invalid.count) line\(preview.invalid.count == 1 ? "" : "s") " +
                        "not recognized", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .help(preview.invalid.prefix(10).joined(separator: "\n"))
                }
            }
            .font(.caption)

            HStack {
                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        draft.text = draft.text.isEmpty ? clip : draft.text + "\n" + clip
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add \(preview.links.count) Link\(preview.links.count == 1 ? "" : "s")") {
                    onAdd(preview.links)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.links.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
