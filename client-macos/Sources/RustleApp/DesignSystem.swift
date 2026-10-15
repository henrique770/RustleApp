import AppKit
import SwiftUI

/// Design tokens recovered from Wispr Flow's renderer CSS (custom properties in the hub/status
/// bundles): the "sand" / "vast" neutrals, accent ramps, type scale and radii.
/// Fonts: Figtree (UI) and EB Garamond (display), both SIL OFL, bundled from Google Fonts.
enum DS {
    // MARK: Palette (exact hex values from the CSS variables)
    static let sand50 = Color(hex: 0xFCFCFB)
    static let sand100 = Color(hex: 0xFAF9F7)
    static let sand200 = Color(hex: 0xF8F7F3)
    static let sand500 = Color(hex: 0xF5F4F0)
    static let sand600 = Color(hex: 0xEEEBE3)
    static let sand700 = Color(hex: 0xC5C0B3)
    static let sand950 = Color(hex: 0x4D4A42)
    static let vast300 = Color(hex: 0xB3B2AD)
    static let vast500 = Color(hex: 0x878683)
    static let vast600 = Color(hex: 0x71716E)
    static let vast700 = Color(hex: 0x5B5B59)
    static let vast900 = Color(hex: 0x30302F)
    static let vast950 = Color(hex: 0x1A1A1A)
    static let dawn100 = Color(hex: 0xFCF7FF)
    static let dawn400 = Color(hex: 0xF4E1FF)
    static let dawn500 = Color(hex: 0xF0D7FF)
    static let dawn700 = Color(hex: 0xA26EC1)
    static let signal500 = Color(hex: 0xFFBCF2)
    static let flare400 = Color(hex: 0xFF6C4C)
    static let glow300 = Color(hex: 0xFFA946)
    static let chord600 = Color(hex: 0x7232A6)
    static let fathom500 = Color(hex: 0x68BDB0)
    static let fathom950 = Color(hex: 0x034F46)
    static let success500 = Color(hex: 0x4FBF78)
    static let destructive500 = Color(hex: 0xEE6A6A)
    static let red600 = Color(hex: 0xDC2626)

    // MARK: Semantic roles (as mapped in the CSS)
    static let background = sand50            // --background
    static let backgroundTertiary = sand500   // --background-tertiary (sidebar / window)
    static let neutral200 = sand600           // --neutral-200 (hover / active)
    static let border = sand600               // --border
    static let card = Color.white             // --card
    static let foreground = vast950           // --foreground
    static let foregroundTertiary = vast600   // --foreground-tertiary
    static let neutral600 = vast900           // --neutral-600 (descriptions)
    static let primary = vast950              // --primary
    static let primaryForeground = sand50     // --primary-foreground

    /// Processing ring: conic-gradient(#f0d7ff, #ffbcf2, #ff6c4c, #ffa946, #7232a6, #f0d7ff)
    static let rainbow: [Color] = [dawn500, signal500, flare400, glow300, chord600, dawn500]

    // MARK: Type
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size).weight(weight)
    }
    /// EB Garamond display face; the CSS pairs it with letter-spacing -0.04em.
    static func display(_ size: CGFloat) -> Font {
        .custom("EB Garamond", size: size)
    }
    /// 550 in CSS sits between medium and semibold.
    static let w550: Font.Weight = .semibold
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Reusable pieces

/// Page title: EB Garamond 28/28, letter-spacing -0.04em (settings .pageTitle).
struct PageTitle: View {
    let text: String
    var size: CGFloat = 28
    var body: some View {
        Text(text)
            .font(DS.display(size))
            .tracking(-0.04 * size)
            .foregroundColor(DS.foreground)
    }
}

/// Uppercase section label: 12/20, weight 600, letter-spacing .075em, tertiary color.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.ui(12, .semibold))
            .tracking(12 * 0.075)
            .foregroundColor(DS.foregroundTertiary)
    }
}

/// Primary (black) button.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.ui(15, DS.w550))
            .foregroundColor(DS.primaryForeground)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.primary.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

/// Secondary (outlined, sand) button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.ui(15, DS.w550))
            .foregroundColor(DS.foreground)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? DS.neutral200 : DS.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Small square icon button (32x32, radius 6, hover neutral-200) like the hub's sidebarAction.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(hover ? DS.foreground : DS.foregroundTertiary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? DS.neutral200 : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// White list card: 1px border, radius 16, rows separated by 1px borders (history/dictionary lists).
struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 16).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Settings card: padding 20, radius 12, background-tertiary.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.backgroundTertiary))
    }
}

/// Single-line text input in the hub style.
struct HubTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(DS.vast500))
            .textFieldStyle(.plain)
            .font(DS.ui(15))
            .foregroundColor(DS.foreground)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
            .onSubmit(onSubmit)
    }
}
