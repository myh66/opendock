import SwiftUI

enum DockTheme {
    static let accent = Color(hex: "8270E8")
    static let ink = Color(hex: "252538")
    static let secondary = Color(hex: "858595")
    static let canvas = Color(hex: "F8F8FB")
    static let line = Color(hex: "EAEAF1")
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean, radix: 16) ?? 0x8B7BF4
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(LinearGradient(colors: [Color(hex: "A598FF"), DockTheme.accent, Color(hex: "655CC4")], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(alignment: .bottom, spacing: size * 0.075) {
                ForEach(0..<3) { i in RoundedRectangle(cornerRadius: size * 0.065).fill(.white.opacity(i == 1 ? 1 : 0.8)).frame(width: size * 0.145, height: size * (i == 1 ? 0.38 : 0.26)) }
            }.padding(.bottom, size * 0.035)
        }.frame(width: size, height: size)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 13).padding(.vertical, 9)
            .background(configuration.isPressed ? DockTheme.line : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DockTheme.line, lineWidth: 1))
    }
}

struct AppIconView: View {
    let item: DockItem
    var size: CGFloat = 48
    var body: some View {
        Image(nsImage: AppService.icon(for: item)).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
    }
}
