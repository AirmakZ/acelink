import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0x0A84FF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct ChannelIconView: View {
    let icon: ChannelIcon
    var size: CGFloat = 28

    var body: some View {
        Group {
            switch icon {
            case let .symbol(name, color):
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color(hex: color).gradient)
                    .overlay(
                        Image(systemName: name)
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundColor(.white)
                    )
            case let .emoji(emoji):
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Text(emoji).font(.system(size: size * 0.62)))
            case let .image(fileName):
                if let image = ChannelStore.iconImage(fileName: fileName) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
                } else {
                    ChannelIconView(icon: .default, size: size)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
