import AppKit

let S: CGFloat = 1024
func col(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx

// Warm near-black background gradient (matches the panel chrome).
NSGradient(colors: [col(0x26, 0x23, 0x18), col(0x12, 0x11, 0x0C)])!
    .draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: -90)

// Soft olive glow centred slightly low, behind the bird.
NSGradient(colors: [col(0x93, 0xA0, 0x63, 0.55), col(0x93, 0xA0, 0x63, 0)])!
    .draw(in: NSRect(x: S*0.10, y: S*0.06, width: S*0.80, height: S*0.80),
          relativeCenterPosition: NSPoint(x: 0, y: -0.05))

// Right-edge accent bar — nods to the edge-docked panel.
col(0xD9, 0x79, 0x5E).setFill()
NSBezierPath(roundedRect: NSRect(x: S - 86, y: S*0.31, width: 30, height: S*0.38),
             xRadius: 15, yRadius: 15).fill()

// Bird mascot (the app's glyph everywhere), tinted cream.
let cfg = NSImage.SymbolConfiguration(pointSize: 640, weight: .semibold)
if let base = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let bs = base.size
    let tinted = NSImage(size: bs)
    tinted.lockFocus()
    base.draw(at: .zero, from: NSRect(origin: .zero, size: bs), operation: .sourceOver, fraction: 1)
    col(0xEC, 0xE6, 0xD6).setFill()
    NSRect(origin: .zero, size: bs).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let scale = (S * 0.50) / max(bs.width, bs.height)
    let w = bs.width * scale, h = bs.height * scale
    tinted.draw(in: NSRect(x: (S - w)/2 - S*0.015, y: (S - h)/2 + S*0.01, width: w, height: h))
}

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments[1]
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
