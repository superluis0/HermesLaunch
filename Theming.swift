import SwiftUI

// MARK: - Theme engine
//
// A `ThemePalette` is the full set of colors that recolors the entire app. Themes
// declare whether they are light or dark so the app can drive `preferredColorScheme`
// and let native chrome (pickers, menus, charts) match. `DS` (DesignSystem.swift)
// reads the active palette from `AppSettings.shared.themeId`, so every view that uses
// a `DS.*` token repaints live when the user picks a new theme.

struct ThemePalette {
    let bg: Color              // window background
    let surface: Color         // cards / panels
    let surfaceElevated: Color // popovers / raised rows
    let border: Color          // hairline separators

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    let accent: Color          // primary brand/accent
    let accent2: Color         // gradient partner

    let success: Color
    let warning: Color
    let danger: Color

    let isDark: Bool
}

extension ThemePalette {
    /// Build a palette from "#RRGGBB" hex strings (compile-time-known, always valid).
    init(bg: String, surface: String, surfaceElevated: String, border: String,
         textPrimary: String, textSecondary: String, textTertiary: String,
         accent: String, accent2: String,
         success: String, warning: String, danger: String,
         isDark: Bool) {
        func h(_ s: String) -> Color { Color(hex: s) ?? .gray }
        self.init(bg: h(bg), surface: h(surface), surfaceElevated: h(surfaceElevated), border: h(border),
                  textPrimary: h(textPrimary), textSecondary: h(textSecondary), textTertiary: h(textTertiary),
                  accent: h(accent), accent2: h(accent2),
                  success: h(success), warning: h(warning), danger: h(danger),
                  isDark: isDark)
    }
}

// MARK: - Theme registry

enum HLTheme: String, CaseIterable, Identifiable {
    case hermes
    case nous
    case midnight
    case ember
    case mono
    case cyberpunk
    case slate
    case catppuccinLatte     = "catppuccin-latte"
    case catppuccinFrappe    = "catppuccin-frappe"
    case catppuccinMacchiato = "catppuccin-macchiato"
    case catppuccinMocha     = "catppuccin-mocha"
    case dracula
    case tokyoNight          = "tokyo-night"
    case nord
    case gruvbox
    case rosePine            = "rose-pine"

    static let fallback: HLTheme = .hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hermes:             return "Hermes"
        case .nous:               return "Azul"
        case .midnight:           return "Midnight"
        case .ember:              return "Fireside"
        case .mono:               return "Mono"
        case .cyberpunk:          return "Keanu"
        case .slate:              return "Slate"
        case .catppuccinLatte:    return "Catppuccin Latte"
        case .catppuccinFrappe:   return "Catppuccin Frappé"
        case .catppuccinMacchiato:return "Catppuccin Macchiato"
        case .catppuccinMocha:    return "Catppuccin Mocha"
        case .dracula:            return "Dracula"
        case .tokyoNight:         return "Tokyo Night"
        case .nord:               return "Nord"
        case .gruvbox:            return "Gruvbox"
        case .rosePine:           return "Rosé Pine"
        }
    }

    var blurb: String {
        switch self {
        case .hermes:             return "Signature violet → pink on deep space"
        case .nous:               return "Glass neutrals with cool blue accents"
        case .midnight:           return "Deep blue-violet with cool accents"
        case .ember:              return "Warm crimson and bronze — forge vibes"
        case .mono:               return "Clean grayscale — minimal and focused"
        case .cyberpunk:          return "Neon green on black — matrix terminal"
        case .slate:              return "Cool slate blue — focused developer theme"
        case .catppuccinLatte:    return "Soft pastel light — warm and gentle"
        case .catppuccinFrappe:   return "Muted dark pastels — cozy"
        case .catppuccinMacchiato:return "Medium-dark pastels — balanced"
        case .catppuccinMocha:    return "The classic dark Catppuccin"
        case .dracula:            return "Iconic purple & pink on charcoal"
        case .tokyoNight:         return "Calm neon blues — late-night coding"
        case .nord:               return "Arctic, frost-blue palette"
        case .gruvbox:            return "Retro warm — orange & green on brown"
        case .rosePine:           return "Natural pine, dusk iris & rose"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .hermes:
            return ThemePalette(
                bg: "#16131F", surface: "#201B2E", surfaceElevated: "#2A2440", border: "#3A3352",
                textPrimary: "#F5F2FB", textSecondary: "#B7AECB", textTertiary: "#7E7796",
                accent: "#8C59F5", accent2: "#ED5C9E",
                success: "#4DC777", warning: "#FAB534", danger: "#F05660", isDark: true)
        case .nous:
            return ThemePalette(
                bg: "#F4F6FB", surface: "#FFFFFF", surfaceElevated: "#EDF1F8", border: "#D9DFEA",
                textPrimary: "#1B2330", textSecondary: "#4A5568", textTertiary: "#6B7890",
                accent: "#3B6EF5", accent2: "#6E9BFF",
                success: "#2BA672", warning: "#D9930B", danger: "#DB4B4B", isDark: false)
        case .midnight:
            return ThemePalette(
                bg: "#0E1224", surface: "#161B33", surfaceElevated: "#1F2547", border: "#2C3358",
                textPrimary: "#E8ECFF", textSecondary: "#A9B2D6", textTertiary: "#6E769B",
                accent: "#6C7CF0", accent2: "#9A6BF0",
                success: "#46C98B", warning: "#E7B34A", danger: "#EC6A6A", isDark: true)
        case .ember:
            return ThemePalette(
                bg: "#1A1110", surface: "#251715", surfaceElevated: "#32201C", border: "#432A24",
                textPrimary: "#FBEDE6", textSecondary: "#D3B3A6", textTertiary: "#97766B",
                accent: "#E2562F", accent2: "#C9892E",
                success: "#4DBE6B", warning: "#E9A52F", danger: "#E5484D", isDark: true)
        case .mono:
            return ThemePalette(
                bg: "#121212", surface: "#1C1C1C", surfaceElevated: "#262626", border: "#383838",
                textPrimary: "#F2F2F2", textSecondary: "#ABABAB", textTertiary: "#6E6E6E",
                accent: "#E6E6E6", accent2: "#9A9A9A",
                success: "#8FB89A", warning: "#C9B27D", danger: "#C98B8B", isDark: true)
        case .cyberpunk:
            return ThemePalette(
                bg: "#050A05", surface: "#0B140B", surfaceElevated: "#112011", border: "#1C341C",
                textPrimary: "#CFFFD0", textSecondary: "#6FCF6F", textTertiary: "#3E7A3E",
                accent: "#39FF14", accent2: "#16C60C",
                success: "#39FF14", warning: "#E8E84A", danger: "#FF5C57", isDark: true)
        case .slate:
            return ThemePalette(
                bg: "#11151C", surface: "#1A2029", surfaceElevated: "#232C38", border: "#323D4D",
                textPrimary: "#E7EDF5", textSecondary: "#A6B2C2", textTertiary: "#6B7686",
                accent: "#4F8FD6", accent2: "#5FB3C9",
                success: "#4DBE82", warning: "#D9A441", danger: "#DB5C61", isDark: true)
        case .catppuccinLatte:
            return ThemePalette(
                bg: "#EFF1F5", surface: "#FFFFFF", surfaceElevated: "#E6E9EF", border: "#BCC0CC",
                textPrimary: "#4C4F69", textSecondary: "#5C5F77", textTertiary: "#8C8FA1",
                accent: "#8839EF", accent2: "#1E66F5",
                success: "#40A02B", warning: "#DF8E1D", danger: "#D20F39", isDark: false)
        case .catppuccinFrappe:
            return ThemePalette(
                bg: "#303446", surface: "#414559", surfaceElevated: "#51576D", border: "#626880",
                textPrimary: "#C6D0F5", textSecondary: "#B5BFE2", textTertiary: "#A5ADCE",
                accent: "#CA9EE6", accent2: "#8CAAEE",
                success: "#A6D189", warning: "#E5C890", danger: "#E78284", isDark: true)
        case .catppuccinMacchiato:
            return ThemePalette(
                bg: "#24273A", surface: "#363A4F", surfaceElevated: "#494D64", border: "#5B6078",
                textPrimary: "#CAD3F5", textSecondary: "#B8C0E0", textTertiary: "#A5ADCB",
                accent: "#C6A0F6", accent2: "#8AADF4",
                success: "#A6DA95", warning: "#EED49F", danger: "#ED8796", isDark: true)
        case .catppuccinMocha:
            return ThemePalette(
                bg: "#1E1E2E", surface: "#313244", surfaceElevated: "#45475A", border: "#585B70",
                textPrimary: "#CDD6F4", textSecondary: "#BAC2DE", textTertiary: "#A6ADC8",
                accent: "#CBA6F7", accent2: "#89B4FA",
                success: "#A6E3A1", warning: "#F9E2AF", danger: "#F38BA8", isDark: true)
        case .dracula:
            return ThemePalette(
                bg: "#282A36", surface: "#343746", surfaceElevated: "#424450", border: "#4B4E63",
                textPrimary: "#F8F8F2", textSecondary: "#C8CEDB", textTertiary: "#6272A4",
                accent: "#BD93F9", accent2: "#FF79C6",
                success: "#50FA7B", warning: "#F1FA8C", danger: "#FF5555", isDark: true)
        case .tokyoNight:
            return ThemePalette(
                bg: "#1A1B26", surface: "#1F2335", surfaceElevated: "#24283B", border: "#2F344D",
                textPrimary: "#C0CAF5", textSecondary: "#A9B1D6", textTertiary: "#565F89",
                accent: "#7AA2F7", accent2: "#BB9AF7",
                success: "#9ECE6A", warning: "#E0AF68", danger: "#F7768E", isDark: true)
        case .nord:
            return ThemePalette(
                bg: "#2E3440", surface: "#3B4252", surfaceElevated: "#434C5E", border: "#4C566A",
                textPrimary: "#ECEFF4", textSecondary: "#D8DEE9", textTertiary: "#8893A5",
                accent: "#88C0D0", accent2: "#5E81AC",
                success: "#A3BE8C", warning: "#EBCB8B", danger: "#BF616A", isDark: true)
        case .gruvbox:
            return ThemePalette(
                bg: "#282828", surface: "#3C3836", surfaceElevated: "#504945", border: "#665C54",
                textPrimary: "#EBDBB2", textSecondary: "#BDAE93", textTertiary: "#928374",
                accent: "#FE8019", accent2: "#B8BB26",
                success: "#B8BB26", warning: "#FABD2F", danger: "#FB4934", isDark: true)
        case .rosePine:
            return ThemePalette(
                bg: "#191724", surface: "#1F1D2E", surfaceElevated: "#26233A", border: "#403D52",
                textPrimary: "#E0DEF4", textSecondary: "#908CAA", textTertiary: "#6E6A86",
                accent: "#C4A7E7", accent2: "#EBBCBA",
                success: "#56949F", warning: "#F6C177", danger: "#EB6F92", isDark: true)
        }
    }
}
