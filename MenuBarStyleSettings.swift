import Cocoa
import SwiftUI

// Feature 8 — customizable menu-bar "Show model" text effect.
// Shared between the real menu bar (HermesLaunch.swift) and the live preview here,
// so the color math has a single source of truth.

// MARK: - Persisted style

struct MenuBarStyle: Codable, Equatable {
    enum Style: String, Codable, CaseIterable { case rainbow, solid, gradient, pulse }
    var style: Style = .rainbow
    var colorsHex: [String] = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#0A84FF", "#5E5CE6"]
    var speed: Double = 0.5         // 0…1
    var tightness: Double = 0.5     // 0…1
    var onlyWhileRunning: Bool = true

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
}

// MARK: - View model

final class MenuBarStyleModel: ObservableObject {
    @Published var style: MenuBarStyle { didSet { onChange?(style) } }
    var onChange: ((MenuBarStyle) -> Void)?
    init(style: MenuBarStyle) { self.style = style }
}

// MARK: - Settings view

struct MenuBarStyleView: View {
    @ObservedObject var model: MenuBarStyleModel
    private let sampleText = "gpt-5.5"

    private var s: Binding<MenuBarStyle> { $model.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Menu Bar Style").font(.system(size: 16, weight: .bold))

            preview

            Picker("Style", selection: s.style) {
                Text("Rainbow").tag(MenuBarStyle.Style.rainbow)
                Text("Solid").tag(MenuBarStyle.Style.solid)
                Text("Gradient wave").tag(MenuBarStyle.Style.gradient)
                Text("Pulse").tag(MenuBarStyle.Style.pulse)
            }
            .pickerStyle(.segmented)

            colorControls

            if model.style.style == .rainbow || model.style.style == .gradient {
                slider("Band tightness", value: s.tightness)
            }
            if MenuBarFX.needsAnimation(model.style.style, speed: 1) {
                slider("Speed", value: s.speed)
            }

            Toggle("Animate only while Hermes is running", isOn: s.onlyWhileRunning)
                .toggleStyle(.checkbox)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 380, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Live preview using TimelineView so it animates without a manual timer.
    private var preview: some View {
        TimelineView(.animation) { context in
            let phase = MenuBarFX.frac(context.date.timeIntervalSinceReferenceDate
                                       * (0.15 + model.style.speed * 1.6))
            let chars = Array(sampleText)
            HStack(spacing: 0) {
                ForEach(chars.indices, id: \.self) { i in
                    let animated = MenuBarFX.needsAnimation(model.style.style, speed: model.style.speed)
                    let rgba = MenuBarFX.rgba(style: model.style.style,
                                              palette: model.style.palette,
                                              index: i, count: chars.count,
                                              phase: animated ? phase : 0,
                                              tightness: model.style.tightness)
                    Text(String(chars[i]))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(MenuBarFX.nsColor(rgba)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))
        }
    }

    @ViewBuilder private var colorControls: some View {
        switch model.style.style {
        case .rainbow:
            Text("Rainbow uses the full color spectrum.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .solid, .pulse:
            HStack {
                Text(model.style.style == .pulse ? "Pulse color" : "Color").font(.system(size: 12))
                Spacer()
                colorWell(0)
            }
        case .gradient:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Colors").font(.system(size: 12))
                    Spacer()
                    Button { removeColor() } label: { Image(systemName: "minus") }
                        .disabled(model.style.colorsHex.count <= 2)
                    Button { addColor() } label: { Image(systemName: "plus") }
                        .disabled(model.style.colorsHex.count >= 5)
                }
                HStack(spacing: 8) {
                    ForEach(model.style.colorsHex.indices, id: \.self) { i in colorWell(i) }
                    Spacer()
                }
            }
        }
    }

    private func colorWell(_ i: Int) -> some View {
        ColorPicker("", selection: Binding(
            get: {
                guard i < model.style.colorsHex.count,
                      let rgb = MenuBarFX.rgb(fromHex: model.style.colorsHex[i]) else { return .white }
                return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
                let hex = MenuBarFX.hex(fromRGB: (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)))
                if i < model.style.colorsHex.count { model.style.colorsHex[i] = hex }
            }
        ))
        .labelsHidden()
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }

    private func addColor() {
        if model.style.colorsHex.count < 5 { model.style.colorsHex.append("#5E5CE6") }
    }
    private func removeColor() {
        if model.style.colorsHex.count > 2 { model.style.colorsHex.removeLast() }
    }
}
