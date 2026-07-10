import Cocoa

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle mask (macOS-style continuous rounded rect)
let r: CGFloat = 230
let rect = CGRect(x: 0, y: 0, width: S, height: S)
let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
ctx.addPath(path); ctx.clip()

// Diagonal gradient: indigo -> violet -> pink
let cols = [
  NSColor(calibratedRed: 0.35, green: 0.30, blue: 0.85, alpha: 1).cgColor, // indigo
  NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.90, alpha: 1).cgColor, // violet
  NSColor(calibratedRed: 0.92, green: 0.35, blue: 0.70, alpha: 1).cgColor, // pink
]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: cols as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// Soft inner glow bottom-right
if let rg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
    locations: [0, 1]) {
  ctx.drawRadialGradient(rg, startCenter: CGPoint(x: S*0.7, y: S*0.3), startRadius: 0,
                         endCenter: CGPoint(x: S*0.7, y: S*0.3), endRadius: S*0.6, options: [])
}

// White play triangle (rounded), centered, matching the menu-bar glyph
let tri = NSBezierPath()
let cx = S*0.52, cy = S*0.5, w = S*0.26, h = S*0.30
tri.move(to: NSPoint(x: cx - w*0.5, y: cy - h*0.5))
tri.line(to: NSPoint(x: cx - w*0.5, y: cy + h*0.5))
tri.line(to: NSPoint(x: cx + w*0.62, y: cy))
tri.close()
tri.lineJoinStyle = .round
tri.lineWidth = 54
NSColor(white: 1, alpha: 0.96).setStroke()
NSColor(white: 1, alpha: 0.96).setFill()
tri.stroke(); tri.fill()

img.unlockFocus()

let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
