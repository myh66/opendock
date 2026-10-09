import AppKit
import SwiftUI

enum DockTheme {
    static let accent = Color(hex: "7471DE")
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let line = Color(nsColor: .separatorColor).opacity(0.55)
    static let control = Color(nsColor: .controlBackgroundColor)
}

struct DockAppBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            DockTheme.canvas
            if !reduceTransparency {
                LinearGradient(colors: [DockTheme.accent.opacity(scheme == .dark ? 0.10 : 0.065), .clear, Color.blue.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea()
    }
}

/// Glass belongs to navigation and interactive controls; reading surfaces stay quiet.
struct DockGlassSurface: View {
    var cornerRadius: CGFloat = 14
    var tint: Color? = nil
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    @ViewBuilder var body: some View {
        if reduceTransparency || contrast == .increased {
            shape.fill(tint ?? DockTheme.control).overlay(shape.stroke(contrast == .increased ? Color.primary.opacity(0.5) : DockTheme.line))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                if let tint { Color.clear.glassEffect(.regular.tint(tint).interactive(interactive && !reduceMotion), in: shape) }
                else { Color.clear.glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape) }
            } else { fallback }
            #else
            fallback
            #endif
        }
    }

    private var fallback: some View {
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(tint?.opacity(0.88) ?? .clear))
            .overlay(shape.stroke(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.72), lineWidth: 0.8))
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.045), radius: 10, y: 3)
    }
}

struct DockCardSurface: View {
    var cornerRadius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(DockTheme.control.opacity(reduceTransparency ? 1 : scheme == .dark ? 0.75 : 0.86))
            .overlay(shape.stroke(contrast == .increased ? Color.primary.opacity(0.45) : DockTheme.line, lineWidth: 0.8))
            .shadow(color: .black.opacity(scheme == .dark ? 0.055 : 0.018), radius: 12, y: 3)
    }
}

extension View {
    func dockGlass(cornerRadius: CGFloat = 14, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(DockGlassModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
    func dockCard(cornerRadius: CGFloat = 20) -> some View { background(DockCardSurface(cornerRadius: cornerRadius)) }
}

private struct DockGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(interactive && !reduceMotion), in: shape)
            } else {
                content.glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape)
            }
        } else {
            content.background(DockGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
        }
        #else
        content.background(DockGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
        #endif
    }
}

struct DockGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content } }
        else { content }
        #else
        content
        #endif
    }
}

struct DockGlassButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.white : DockTheme.ink)
            .dockGlass(cornerRadius: 12, tint: prominent ? DockTheme.accent : nil, interactive: enabled)
        return DockSelectableCardBody(label: label, pressed: configuration.isPressed, selected: false, cornerRadius: 12)
    }
}

/// Frequent selections use immediate color feedback without moving their contents.
struct DockSelectableCardStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 16
    var showsSelectionBorder = true
    func makeBody(configuration: Configuration) -> some View {
        DockSelectableCardBody(label: configuration.label, pressed: configuration.isPressed,
                               selected: selected, cornerRadius: cornerRadius, showsSelectionBorder: showsSelectionBorder)
    }
}

private struct DockSelectableCardBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let selected: Bool
    let cornerRadius: CGFloat
    var showsSelectionBorder = true
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let emphasized = (selected && showsSelectionBorder) || focused
        label.contentShape(shape)
            .overlay(shape.fill(DockTheme.accent.opacity(enabled ? (pressed ? 0.14 : selected ? 0.08 : hovered ? 0.045 : 0) : 0)).allowsHitTesting(false))
            .overlay(shape.stroke(emphasized ? DockTheme.accent : enabled && hovered ? (contrast == .increased ? Color.primary : DockTheme.line) : .clear,
                                  lineWidth: emphasized ? 1.5 : 1).allowsHitTesting(false))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

struct DockIconButtonStyle: ButtonStyle {
    var prominent = false
    var size: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .frame(width: max(32, size), height: max(32, size))
            .foregroundStyle(prominent ? DockTheme.accent : DockTheme.ink)
            .buttonFeedback(pressed: configuration.isPressed)
    }
}

private extension View {
    func buttonFeedback(pressed: Bool) -> some View {
        DockSelectableCardBody(label: self, pressed: pressed, selected: false, cornerRadius: 10)
    }
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
        DockGlassButtonStyle().makeBody(configuration: configuration)
    }
}

struct AppIconView: View {
    let item: DockItem
    var size: CGFloat = 48
    var body: some View {
        Image(nsImage: AppService.icon(for: item)).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
    }
}
