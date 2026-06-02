import Cocoa
import SwiftUI

// Feature 8 — customizable menu-bar "Show model" text effect.
// Shared between the real menu bar (HermesLaunch.swift) and the live preview here,
// so the color math has a single source of truth.

// MARK: - Persisted style

struct MenuBarStyle: Codable, Equatable {
    enum Style: String, Codable, CaseIterable { case rainbow, solid, gradient, pulse }
    var style: Style = .rainbow
    // Default for solid/gradient/pulse — a distinct 3-color blend (NOT a full
    // spectrum, so Gradient doesn't look like Rainbow). Rainbow ignores this.
    var colorsHex: [String] = ["#0A84FF", "#BF5AF2", "#FF375F"]
    var speed: Double = 0.5         // 0…1
    var tightness: Double = 0.5     // 0…1
    var onlyWhileRunning: Bool = true

    /// The pre-v9 default palette (a full spectrum). Used to migrate existing
    /// users off it so Gradient stops mirroring Rainbow.
    static let legacySpectrumDefault = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#0A84FF", "#5E5CE6"]

    /// Parsed sRGB palette (always ≥1 color).
    var palette: [(r: Double, g: Double, b: Double)] {
        let parsed = colorsHex.compactMap(MenuBarFX.rgb(fromHex:))
        return parsed.isEmpty ? [(1, 1, 1)] : parsed
    }
}

// MARK: - Color math (pure)

enum MenuBarFX {
    static func spread(forTightness t: Double) -> Double { 0.02 + max(0, min(1, t)) * 0.12 }
    static func drift(forSpeed s: Double) -> Double { max(0, min(1, s)) * 0.04 }

    static func needsAnimation(_ style: MenuBarStyle.Style, speed: Double) -> Bool {
        switch style {
        case .solid:  return false
        case .pulse:  return speed > 0.001          // breathing needs motion
        case .rainbow, .gradient: return speed > 0.001
        }
    }

    /// RGBA (0…1) for character `index` of `count`, at animation `phase` (0…1).
    static func rgba(style: MenuBarStyle.Style,
                     palette: [(r: Double, g: Double, b: Double)],
                     index: Int, count: Int, phase: Double, tightness: Double)
        -> (r: Double, g: Double, b: Double, a: Double) {
        let sp = spread(forTightness: tightness)
        switch style {
        case .rainbow:
            let hue = frac(phase + Double(index) * sp)
            let c = hsb(hue, 0.7, 0.95)
            return (c.r, c.g, c.b, 1)
        case .gradient:
            let t = frac(phase + Double(index) * sp)
            let c = sampleCyclic(palette, t)
            return (c.r, c.g, c.b, 1)
        case .solid:
            let c = palette[0]
            return (c.r, c.g, c.b, 1)
        case .pulse:
            let g = 0.45 + 0.55 * (0.5 + 0.5 * sin(2 * .pi * phase))
            let c = palette[0]
            return (c.r * g, c.g * g, c.b * g, 1)
        }
    }

    // helpers
    static func frac(_ x: Double) -> Double { let f = x.truncatingRemainder(dividingBy: 1); return f < 0 ? f + 1 : f }

    static func sampleCyclic(_ p: [(r: Double, g: Double, b: Double)], _ t: Double) -> (r: Double, g: Double, b: Double) {
        let n = p.count
        if n == 1 { return p[0] }
        let scaled = frac(t) * Double(n)
        let i = Int(scaled) % n
        let j = (i + 1) % n
        let f = scaled - Double(Int(scaled))
        return (p[i].r + (p[j].r - p[i].r) * f,
                p[i].g + (p[j].g - p[i].g) * f,
                p[i].b + (p[j].b - p[i].b) * f)
    }

    static func hsb(_ h: Double, _ s: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        let c = NSColor(hue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(b), alpha: 1)
            .usingColorSpace(.sRGB) ?? .white
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    static func rgb(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func hex(fromRGB c: (r: Double, g: Double, b: Double)) -> String {
        func h(_ x: Double) -> String { String(format: "%02X", max(0, min(255, Int((x * 255).rounded())))) }
        return "#\(h(c.r))\(h(c.g))\(h(c.b))"
    }

    static func nsColor(_ c: (r: Double, g: Double, b: Double, a: Double)) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    /// In-app swatch palette: rows of hex. Each hue row runs light→dark; the last
    /// row is neutrals. Used by the color picker UI (no native color panel).
    static let swatches: [[String]] = {
        // 9 base hues (fractions of the wheel) × 5 shades (light → dark).
        let hues: [Double] = [0.00, 0.07, 0.13, 0.33, 0.47, 0.58, 0.66, 0.78, 0.92]
        let shades: [(s: Double, b: Double)] = [
            (0.28, 1.00), (0.55, 0.97), (0.78, 0.90), (0.92, 0.74), (1.00, 0.55),
        ]
        var rows: [[String]] = hues.map { h in
            shades.map { sh in hex(fromRGB: hsb(h, sh.s, sh.b)) }
        }
        // Neutrals row: white → black.
        rows.append(["#FFFFFF", "#C7C7CC", "#8E8E93", "#48484A", "#1C1C1E"])
        return rows
    }()
}

// MARK: - Settings view

struct MenuBarStyleView: View {
    let initial: MenuBarStyle
    var onApply: (MenuBarStyle) -> Void
    var onCancel: () -> Void

    @State private var working: MenuBarStyle
    @State private var activeSlot: Int = 0
    private let sampleText = "gpt-5.5"

    init(initial: MenuBarStyle, onApply: @escaping (MenuBarStyle) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onApply = onApply
        self.onCancel = onCancel
        _working = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Menu Bar Style").font(.system(size: 16, weight: .bold))
                    preview

                    Picker("", selection: $working.style) {
                        Text("Rainbow").tag(MenuBarStyle.Style.rainbow)
                        Text("Solid").tag(MenuBarStyle.Style.solid)
                        Text("Gradient").tag(MenuBarStyle.Style.gradient)
                        Text("Pulse").tag(MenuBarStyle.Style.pulse)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    colorSection

                    if working.style == .rainbow || working.style == .gradient {
                        slider("Band tightness", value: $working.tightness)
                    }
                    if MenuBarFX.needsAnimation(working.style, speed: 1) {
                        slider("Speed", value: $working.speed)
                    }

                    Toggle("Animate only while Hermes is running", isOn: $working.onlyWhileRunning)
                        .toggleStyle(.checkbox)
                }
                .padding(18)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(working) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 400, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Live preview — reads `working`, so every edit repaints. Animates via TimelineView.
    private var preview: some View {
        TimelineView(.animation) { context in
            let animated = MenuBarFX.needsAnimation(working.style, speed: working.speed)
            let phase = animated
                ? MenuBarFX.frac(context.date.timeIntervalSinceReferenceDate * (0.15 + working.speed * 1.6))
                : 0
            let chars = Array(sampleText)
            HStack(spacing: 0) {
                ForEach(chars.indices, id: \.self) { i in
                    let rgba = MenuBarFX.rgba(style: working.style, palette: working.palette,
                                              index: i, count: chars.count,
                                              phase: phase, tightness: working.tightness)
                    Text(String(chars[i]))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(MenuBarFX.nsColor(rgba)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))
        }
    }

    // MARK: color picking (in-app, no native panel)

    @ViewBuilder private var colorSection: some View {
        if working.style == .rainbow {
            Text("Rainbow cycles the full color spectrum — no colors to pick.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                slotRow
                swatchGrid
            }
        }
    }

    private var slotRow: some View {
        let isGradient = working.style == .gradient
        let count = isGradient ? working.colorsHex.count : 1
        return HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in chip(i) }
            if isGradient {
                Button { addColor() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).disabled(working.colorsHex.count >= 5)
                Button { removeColor() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(working.colorsHex.count <= 2)
            }
            Spacer()
        }
    }

    private func chip(_ i: Int) -> some View {
        let isActive = (effectiveSlot == i)
        return RoundedRectangle(cornerRadius: 6)
            .fill(color(forHex: hex(at: i)))
            .frame(width: 36, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.15),
                              lineWidth: isActive ? 3 : 1))
            .onTapGesture { activeSlot = i }
    }

    private var swatchGrid: some View {
        let hueRows = Array(MenuBarFX.swatches.dropLast())   // 9 hue rows × 5 shades
        let neutrals = MenuBarFX.swatches.last ?? []
        let shadeCount = hueRows.first?.count ?? 5
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<shadeCount, id: \.self) { shade in
                HStack(spacing: 6) {
                    ForEach(hueRows.indices, id: \.self) { h in swatch(hueRows[h][shade]) }
                }
            }
            HStack(spacing: 6) {
                ForEach(neutrals.indices, id: \.self) { i in swatch(neutrals[i]) }
            }
        }
    }

    private func swatch(_ hexStr: String) -> some View {
        let selected = hex(at: effectiveSlot).caseInsensitiveCompare(hexStr) == .orderedSame
        return RoundedRectangle(cornerRadius: 5)
            .fill(color(forHex: hexStr))
            .frame(width: 30, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.primary : Color.primary.opacity(0.12),
                              lineWidth: selected ? 2.5 : 0.5))
            .onTapGesture { setActiveColor(hexStr) }
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }

    // MARK: helpers

    /// The slot index currently being edited (always 0 for solid/pulse).
    private var effectiveSlot: Int {
        working.style == .gradient ? min(activeSlot, working.colorsHex.count - 1) : 0
    }

    private func hex(at i: Int) -> String {
        (i >= 0 && i < working.colorsHex.count) ? working.colorsHex[i] : "#FFFFFF"
    }

    private func color(forHex h: String) -> Color {
        let rgb = MenuBarFX.rgb(fromHex: h) ?? (1, 1, 1)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private func setActiveColor(_ h: String) {
        let i = effectiveSlot
        guard i >= 0, i < working.colorsHex.count else {
            if working.colorsHex.isEmpty { working.colorsHex = [h] }
            return
        }
        working.colorsHex[i] = h
    }

    private func addColor() {
        if working.colorsHex.count < 5 {
            working.colorsHex.append(working.colorsHex.last ?? "#5E5CE6")
            activeSlot = working.colorsHex.count - 1
        }
    }
    private func removeColor() {
        if working.colorsHex.count > 2 {
            working.colorsHex.removeLast()
            activeSlot = min(activeSlot, working.colorsHex.count - 1)
        }
    }
}
