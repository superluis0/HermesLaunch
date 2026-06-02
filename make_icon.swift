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
let cx = size * 0.46
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

// ---- Wing fanning off the top-right shoulder ----
NSShadow().set()  // clear shadow for crisp wing
glyphColor.setFill()

// All feathers fan from a common origin just above the right post's top.
let originX = left + postW + gap + postW * 0.85
let originY = bottom + hH - postW * 0.35

// Curved, tapered feathers: long leading feather at the bottom, shorter toward the top.
struct Feather { let len: CGFloat; let angleDeg: CGFloat; let baseHalf: CGFloat; let curl: CGFloat }
let feathers = [
    Feather(len: size * 0.350, angleDeg: 13, baseHalf: size * 0.058, curl: size * 0.055),
    Feather(len: size * 0.300, angleDeg: 23, baseHalf: size * 0.055, curl: size * 0.048),
    Feather(len: size * 0.246, angleDeg: 34, baseHalf: size * 0.050, curl: size * 0.040),
    Feather(len: size * 0.185, angleDeg: 46, baseHalf: size * 0.044, curl: size * 0.032),
]
for f in feathers {
    let a = f.angleDeg * .pi / 180
    let dx = cos(a), dy = sin(a)
    let nx = -sin(a), ny = cos(a)            // unit normal (points "up/left" of the blade)
    let bx = originX, by = originY            // base center
    // Tip, with an upward curl perpendicular to the blade direction.
    let tx = bx + dx * f.len + nx * f.curl
    let ty = by + dy * f.len + ny * f.curl
    let h = f.baseHalf
    let mid = CGFloat(0.5)
    // Leading edge (outer) bows out; trailing edge (inner) bows in — meeting at a point.
    let path = NSBezierPath()
    path.move(to: NSPoint(x: bx + nx * h, y: by + ny * h))
    path.curve(to: NSPoint(x: tx, y: ty),
               controlPoint1: NSPoint(x: bx + dx * f.len * mid + nx * (h + f.curl * 0.6),
                                      y: by + dy * f.len * mid + ny * (h + f.curl * 0.6)),
               controlPoint2: NSPoint(x: tx - dx * f.len * 0.18 + nx * h * 0.3,
                                      y: ty - dy * f.len * 0.18 + ny * h * 0.3))
    path.curve(to: NSPoint(x: bx - nx * h, y: by - ny * h),
               controlPoint1: NSPoint(x: tx - dx * f.len * 0.18 - nx * h * 0.3,
                                      y: ty - dy * f.len * 0.18 - ny * h * 0.3),
               controlPoint2: NSPoint(x: bx + dx * f.len * mid - nx * (h * 0.2),
                                      y: by + dy * f.len * mid - ny * (h * 0.2)))
    path.close()
    path.fill()
}

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
