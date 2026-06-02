import Cocoa

let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

// Squircle background — system blue gradient, macOS-app style.
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = size * 0.22 // approximates macOS squircle
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1.0),
    NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.95, alpha: 1.0)
])!
gradient.draw(in: path, angle: -90)

// Paperplane SF Symbol, white, large.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.62, weight: .regular)
    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
if let sym = NSImage(systemSymbolName: "paperplane.fill",
                     accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let symSize = sym.size
    // Slight upward + leftward bias so the plane looks visually centered
    // (the symbol's bbox has empty space in the lower-right).
    let dx = (size - symSize.width) / 2 - size * 0.02
    let dy = (size - symSize.height) / 2 + size * 0.02
    sym.draw(in: NSRect(x: dx, y: dy, width: symSize.width, height: symSize.height),
             from: .zero, operation: .sourceOver, fraction: 1.0)
}

canvas.unlockFocus()

// Write 1024 PNG
guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render PNG\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
