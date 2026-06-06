import SwiftUI
import AppKit

// MARK: - Design System (ADA backbone)
//
// Central visual tokens + reusable components so every window shares one language.
// Namespaced under `DS` (tokens) and `HL` (components/styles) to avoid collisions
// with the per-window inline styling already in the codebase. New windows should
// build from these; existing windows can migrate opportunistically.

enum DS {
    /// The active palette, resolved from the user's chosen theme. Re-read on every
    /// access so any view using a DS token repaints live when the theme changes
    /// (AppSettings fires objectWillChange; observers re-evaluate these computed vars).
    static var theme: ThemePalette {
        (HLTheme(rawValue: AppSettings.shared.themeId) ?? .fallback).palette
    }

    // Legacy brand constants (kept for any remaining direct references).
    static let violet = Color(red: 0.55, green: 0.35, blue: 0.96)
    static let pink   = Color(red: 0.93, green: 0.36, blue: 0.62)

    // Accent + brand gradient — now sourced from the active theme.
    static var accent: Color { theme.accent }

    /// Readable text/icon color to place *on top of* the accent (handles light
    /// accents like Mono's near-white, where white-on-accent would be invisible).
    static var onAccent: Color {
        let c = NSColor(theme.accent).usingColorSpace(.sRGB)
        let lum = c.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? 0
        return lum > 0.6 ? Color.black.opacity(0.85) : .white
    }
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [theme.accent, theme.accent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Surfaces & text (themed).
    static var bg: Color              { theme.bg }
    static var surface: Color         { theme.surface }
    static var surfaceElevated: Color { theme.surfaceElevated }
    static var border: Color          { theme.border }
    static var textPrimary: Color     { theme.textPrimary }
    static var textSecondary: Color   { theme.textSecondary }
    static var textTertiary: Color    { theme.textTertiary }

    // Semantic status colors (themed).
    static var success: Color { theme.success }
    static var warning: Color { theme.warning }
    static var danger: Color  { theme.danger }

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
                    .fill(DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.border.opacity(0.6))
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
            .foregroundStyle(DS.onAccent)
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
            .background(DS.textPrimary.opacity(configuration.isPressed ? 0.16 : 0.08))
            .foregroundStyle(DS.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
    }
}

extension ButtonStyle where Self == HLPrimaryButtonStyle {
    static var hlPrimary: HLPrimaryButtonStyle { HLPrimaryButtonStyle() }
}
extension ButtonStyle where Self == HLSecondaryButtonStyle {
    static var hlSecondary: HLSecondaryButtonStyle { HLSecondaryButtonStyle() }
}

// MARK: - Themed scene wrapper

/// Wraps a root view hosted in its own NSWindow/NSPanel so it observes AppSettings
/// and re-applies the active theme's tint + color scheme live (the main AppShellView
/// already observes AppSettings; standalone hosting views need this shim).
struct ThemedScene<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .tint(DS.accent)
            .preferredColorScheme(DS.theme.isDark ? .dark : .light)
    }
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
