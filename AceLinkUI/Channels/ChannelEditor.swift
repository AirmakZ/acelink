import SwiftUI
import UniformTypeIdentifiers

final class ChannelDraft: ObservableObject {
    enum IconKind: String, CaseIterable {
        case symbol = "Symbol"
        case emoji = "Emoji"
        case image = "Image"
    }

    @Published var channel: Channel
    @Published var kind: IconKind = .symbol
    @Published var symbolName = "tv"
    @Published var symbolColor = "#0A84FF"
    @Published var emoji = "⚽️"
    @Published var imageFileName: String?

    init(channel: Channel) {
        self.channel = channel
        switch channel.icon {
        case let .symbol(name, color):
            kind = .symbol
            symbolName = name
            symbolColor = color
        case let .emoji(value):
            kind = .emoji
            emoji = value
        case let .image(fileName):
            kind = .image
            imageFileName = fileName
        }
    }

    var icon: ChannelIcon {
        switch kind {
        case .symbol: return .symbol(name: symbolName, color: symbolColor)
        case .emoji: return .emoji(emoji.isEmpty ? "📺" : String(emoji.prefix(1)))
        case .image:
            if let imageFileName = imageFileName { return .image(fileName: imageFileName) }
            return .symbol(name: symbolName, color: symbolColor)
        }
    }
}

struct ChannelEditor: View {
    @StateObject private var draft: ChannelDraft
    let isNew: Bool
    let onSave: (Channel) -> Void
    let onCancel: () -> Void

    init(channel: Channel, isNew: Bool, onSave: @escaping (Channel) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: ChannelDraft(channel: channel))
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    static let symbols = [
        "tv", "play.tv", "play.rectangle.fill", "film", "sportscourt", "soccerball",
        "basketball", "football", "baseball", "tennis.racket", "hockey.puck", "volleyball",
        "figure.run", "figure.soccer", "trophy", "medal", "flag.checkered", "car",
        "bicycle", "flame", "star", "heart", "bolt", "globe",
        "antenna.radiowaves.left.and.right", "music.note", "newspaper", "theatermasks",
        "gamecontroller", "sparkles"
    ]

    static let colors = [
        "#0A84FF", "#30B0C7", "#34C759", "#FFCC00", "#FF9500",
        "#FF3B30", "#FF2D55", "#AF52DE", "#5856D6", "#8E8E93"
    ]

    private var canSave: Bool {
        !draft.channel.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Channel" : "Edit Channel").font(.headline)

            HStack(spacing: 14) {
                ChannelIconView(icon: draft.icon, size: 56)
                TextField("Channel name", text: $draft.channel.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
            }

            Picker("Icon", selection: $draft.kind) {
                ForEach(ChannelDraft.IconKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                switch draft.kind {
                case .symbol: symbolPicker
                case .emoji: emojiPicker
                case .image: imagePicker
                }
            }
            .frame(height: 190, alignment: .top)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    var saved = draft.channel
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.icon = draft.icon
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 10), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { name in
                    Button {
                        draft.symbolName = name
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 15))
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(name == draft.symbolName ? Color.accentColor.opacity(0.25) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            HStack(spacing: 8) {
                ForEach(Self.colors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().stroke(Color.primary, lineWidth: hex == draft.symbolColor ? 2 : 0)
                        )
                        .onTapGesture { draft.symbolColor = hex }
                }
            }
        }
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Emoji", text: $draft.emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Button("Emoji Picker…") { NSApp.orderFrontCharacterPalette(nil) }
            }
            Text("Type or pick a single emoji, e.g. ⚽️ 🏀 🏎️ 🎾 📺")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var imagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Choose Image…", action: chooseImage)
            Text("PNG, JPEG, or any image. It will be cropped to a square.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.message = "Choose an image for this channel"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let fileName = ChannelStore.importIcon(from: url) {
            draft.imageFileName = fileName
        }
    }
}
