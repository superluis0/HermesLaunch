import SwiftUI
import AppKit

// MARK: - Design System (ADA backbone)
//
// Central visual tokens + reusable components so every window shares one language.
// Namespaced under `DS` (tokens) and `HL` (components/styles) to avoid collisions
// with the per-window inline styling already in the codebase. New windows should
// build from these; existing windows can migrate opportunistically.

enum DS {
    // Brand gradient: violet → pink by default, or a user-chosen tint.
    static let violet = Color(red: 0.55, green: 0.35, blue: 0.96)
    static let pink   = Color(red: 0.93, green: 0.36, blue: 0.62)

    /// User's custom brand color, if set (drives the sidebar mark + accents app-wide).
    static var customBrand: Color? {
        guard let hex = AppSettings.shared.brandColorHex else { return nil }
        return Color(hex: hex)
    }
    static var brandGradient: LinearGradient {
        if let c = customBrand {
            return LinearGradient(colors: [c, c.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var accent: Color { customBrand ?? violet }

    // Semantic colors.
    static let success = Color(red: 0.30, green: 0.78, blue: 0.47)
    static let warning = Color(red: 0.98, green: 0.71, blue: 0.20)
    static let danger  = Color(red: 0.94, green: 0.34, blue: 0.38)

    // Typography scale (matches the sizes already used across windows).
    enum Typography {
        static let title   = Font.system(size: 17, weight: .bold)
        static let heading = Font.system(size: 13, weight: .semibold)
        static let body    = Font.system(size: 13)
        static let caption = Font.system(size: 11)
        static let micro   = Font.system(size: 10, weight: .medium)
        static let mono    = Font.system(size: 11.5, design: .monospaced)
    }

    // Spacing tokens.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // Corner radii.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
    }

    // Motion constants.
    enum Motion {
        static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static let quick  = Animation.easeOut(duration: 0.16)
    }
}

// MARK: - Components

/// Vibrancy background (wraps `NSVisualEffectView`) for panels and windows.
struct HLVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// A muted section header with optional subtitle.
struct HLSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Typography.heading).foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle).font(DS.Typography.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rounded card container with a hairline border.
struct HLCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(DS.Space.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

/// A labeled switch row.
struct HLToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typography.body)
                if let subtitle {
                    Text(subtitle).font(DS.Typography.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, DS.Space.xs)
    }
}

/// Small colored status indicator dot.
struct HLStatusDot: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

// MARK: - Button styles

struct HLPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.body.weight(.semibold))
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(DS.brandGradient.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DS.Motion.quick, value: configuration.isPressed)
    }
}

struct HLSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.body)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
    }
}

extension ButtonStyle where Self == HLPrimaryButtonStyle {
    static var hlPrimary: HLPrimaryButtonStyle { HLPrimaryButtonStyle() }
}
extension ButtonStyle where Self == HLSecondaryButtonStyle {
    static var hlSecondary: HLSecondaryButtonStyle { HLSecondaryButtonStyle() }
}

// MARK: - Color hex helpers

extension Color {
    /// Parse "#RRGGBB" (or "RRGGBB"). Returns nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255.0,
                  green: Double((v >> 8) & 0xFF) / 255.0,
                  blue: Double(v & 0xFF) / 255.0)
    }

    /// "#RRGGBB" in sRGB, or nil if the color can't be converted.
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
