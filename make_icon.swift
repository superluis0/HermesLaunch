import Cocoa

// Generates the 1024×1024 app icon: a Hermes-themed winged "H" monogram on an
// amber→gold squircle. Run via make_icons.sh, which resizes it into the iconset
// and builds AppIcon.icns.

let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()
let ctx = NSGraphicsContext.current!
ctx.imageInterpolation = .high

// ---- Squircle background: amber → deep gold ----
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius = size * 0.225
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let bg = NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 0.78, blue: 0.32, alpha: 1.0),  // bright amber (top)
    NSColor(srgbRed: 0.95, green: 0.55, blue: 0.07, alpha: 1.0),  // gold
    NSColor(srgbRed: 0.85, green: 0.40, blue: 0.04, alpha: 1.0),  // deep amber (bottom)
])!
bg.draw(in: squircle, angle: -90)

// Subtle top sheen for depth.
squircle.addClip()
let sheen = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.22),
    NSColor(white: 1.0, alpha: 0.0),
])!
sheen.draw(in: NSRect(x: 0, y: size * 0.52, width: size, height: size * 0.48), angle: -90)

// ---- Geometry for the "H" ----
let glyphColor = NSColor.white
let hH = size * 0.46          // height of the H
let postW = size * 0.115      // width of each vertical post
let gap = size * 0.165        // inner gap between posts
let hW = postW * 2 + gap      // total H width
let cx = size * 0.50
let cy = size * 0.50
let left = cx - hW / 2
let bottom = cy - hH / 2
let crossH = size * 0.115     // crossbar thickness

let corner = postW * 0.32
func roundedRect(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner) }

// Soft drop shadow under the whole monogram.
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0.0, alpha: 0.28)
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
shadow.shadowBlurRadius = size * 0.03
shadow.set()

// Union the three bars into ONE path so the shadow wraps the silhouette
// (no internal seams where the bars overlap).
let hPath = NSBezierPath()
hPath.windingRule = .nonZero
hPath.append(roundedRect(NSRect(x: left, y: bottom, width: postW, height: hH)))                  // left post
hPath.append(roundedRect(NSRect(x: left + postW + gap, y: bottom, width: postW, height: hH)))     // right post
hPath.append(roundedRect(NSRect(x: left, y: cy - crossH / 2, width: hW, height: crossH)))         // crossbar
glyphColor.setFill()
hPath.fill()

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render PNG\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
