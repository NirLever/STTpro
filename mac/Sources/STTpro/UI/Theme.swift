import AppKit
import SwiftUI

/// The Windows app's palette (src/STTpro.App/Themes/Palette.Light.xaml and
/// Palette.Dark.xaml), as colors that switch with the macOS appearance.
enum Theme {
    private static func argb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: CGFloat((v >> 24) & 0xFF) / 255)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? argb(dark) : argb(light)
        })
    }

    // Surfaces
    static let bgPrimary = dynamic(0xFFF4F5F7, 0xFF161619)
    static let bgCard = dynamic(0xFFFFFFFF, 0xFF1F1F24)
    static let bgInput = dynamic(0xFFEDEEF2, 0xFF2A2A31)
    static let bgElevated = dynamic(0xFFFFFFFF, 0xFF26262C)
    // Borders
    static let border = dynamic(0xFFE3E3E9, 0xFF34343B)
    static let borderStrong = dynamic(0xFFCFCFD6, 0xFF47474F)
    // Text
    static let textPrimary = dynamic(0xFF1C1C1E, 0xFFF4F4F6)
    static let textSecondary = dynamic(0xFF56565E, 0xFFAEAEB8)
    static let textMuted = dynamic(0xFF8E8E96, 0xFF7E7E88)
    static let textOnAccent = Color.white
    // Accents
    static let accentBlue = dynamic(0xFF007AFF, 0xFF0A84FF)
    static let accentBlueHover = dynamic(0xFF2B90FF, 0xFF3D9BFF)
    static let accentGreen = dynamic(0xFF2FA84C, 0xFF32D74B)
    static let accentRed = dynamic(0xFFFF3B30, 0xFFFF453A)
    static let accentOrange = dynamic(0xFFD97A00, 0xFFFF9F0A)
    // Overlays / tints
    static let hoverOverlay = dynamic(0x0F000000, 0x14FFFFFF)
    static let pressOverlay = dynamic(0x18000000, 0x22FFFFFF)
    static let selectedOverlay = dynamic(0x14007AFF, 0x2A0A84FF)
    static let badgeBlueBg = dynamic(0x14007AFF, 0x2A0A84FF)
    static let badgeOrangeBg = dynamic(0x1AD97A00, 0x2AFF9F0A)
    static let accentBorderSubtle = dynamic(0x40007AFF, 0x550A84FF)
    static let shadow = dynamic(0x25000000, 0x66000000)

    /// "system" follows macOS; "light"/"dark" force it (Windows "Appearance" setting).
    @MainActor static func apply(mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - Text styles (Controls.xaml: SectionLabel / FieldLabel / HintLabel)

extension Text {
    func sectionLabel() -> some View {
        self.font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(Theme.textMuted)
    }
    func fieldLabel() -> some View {
        self.font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    }
    func hintLabel() -> some View {
        self.font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { Text(title.uppercased()).sectionLabel().padding(.bottom, 10) }
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: Theme.shadow.opacity(0.5), radius: 6, y: 1)
    }
}

// MARK: - Buttons

enum STTButtonKind { case primary, secondary, mini, delete, hotkey }

struct STTButtonStyle: ButtonStyle {
    var kind: STTButtonKind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, isEnabled: isEnabled)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: STTButtonKind
        let isEnabled: Bool
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: kind == .mini || kind == .hotkey ? .regular : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .background(RoundedRectangle(cornerRadius: 7).fill(background))
                .overlay(RoundedRectangle(cornerRadius: 7).fill(overlay))
                .overlay(kind == .hotkey ? RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border) : nil)
                .opacity(isEnabled ? (configuration.isPressed && kind == .delete ? 0.72 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fontSize: CGFloat { kind == .mini ? 10.5 : (kind == .hotkey ? 12 : 13) }
        private var hPad: CGFloat { kind == .mini ? 8 : (kind == .hotkey ? 12 : 16) }
        private var vPad: CGFloat { kind == .mini ? 4 : (kind == .hotkey ? 7 : 9) }

        private var background: Color {
            switch kind {
            case .primary: return hovering ? Theme.accentBlueHover : Theme.accentBlue
            case .delete: return Theme.accentRed
            default: return Theme.bgInput
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary, .delete: return Theme.textOnAccent
            default: return Theme.textPrimary
            }
        }

        private var overlay: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return kind == .delete ? .clear : Theme.pressOverlay }
            if hovering { return kind == .primary ? .clear : (kind == .delete ? Color.white.opacity(0.12) : Theme.hoverOverlay) }
            return .clear
        }
    }
}

extension View {
    func sttButton(_ kind: STTButtonKind = .primary) -> some View { buttonStyle(STTButtonStyle(kind: kind)) }
}

// MARK: - Inputs

/// TextBox / PasswordBox look: filled, rounded, accent border on focus.
struct STTFieldStyle: ViewModifier {
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgInput))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accentBlue : Theme.border, lineWidth: focused ? 1.5 : 1))
    }
}

struct STTTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
            }
        }
        .focused($focused)
        .onSubmit(onSubmit)
        .autocorrectionDisabled()
        .modifier(STTFieldStyle(focused: focused))
    }
}

/// ComboBox look: a filled field with ▾ that opens a menu.
struct STTDropdown<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var width: CGFloat? = nil

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.label) { selection = option.value }
            }
        } label: {
            HStack {
                Text(options.first { $0.value == selection }?.label ?? "—")
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "triangle.fill").rotationEffect(.degrees(180))
                    .font(.system(size: 7)).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgInput))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width != nil, vertical: true)
    }
}

/// Windows-style checkbox: rounded square, accent fill with a white check.
struct STTCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(configuration.isOn ? Theme.accentBlue : Theme.bgInput)
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(configuration.isOn ? Theme.accentBlue : Theme.borderStrong)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
                configuration.label.font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.1), value: configuration.isOn)
    }
}

struct STTRadio: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.bgInput)
                    Circle().strokeBorder(selected ? Theme.accentBlue : Theme.borderStrong, lineWidth: selected ? 1.5 : 1)
                    if selected { Circle().fill(Theme.accentBlue).frame(width: 9, height: 9) }
                }
                .frame(width: 20, height: 20)
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small pill badge (history language / prompt name).
struct Badge: View {
    let text: String
    var color: Color = Theme.accentBlue
    var background: Color = Theme.badgeBlueBg

    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
    }
}

/// "STT" bold accent + "pro" light, as in the Windows header.
struct BrandTitle: View {
    var first = "STT"
    var second = "pro"
    var size: CGFloat = 23

    var body: some View {
        (Text(first).font(.system(size: size, weight: .bold)).foregroundColor(Theme.accentBlue)
         + Text(second).font(.system(size: size, weight: .light)).foregroundColor(Theme.textPrimary))
    }
}
