// Renders the app icon (dark tile, blue line-art remote display + prompt) into an .iconset.
// Usage: swift scripts/make-app-icon.swift <out.iconset>   then: iconutil -c icns <out.iconset>
import AppKit

let accent = NSColor(srgbRed: 0.20, green: 0.55, blue: 1.00, alpha: 1)
let accentDeep = NSColor(srgbRed: 0.04, green: 0.38, blue: 0.90, alpha: 1)

func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px) / 1024  // design on a 1024 grid

  // macOS icon grid: 824pt tile centered, ~185pt corner radius.
  let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
  let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
  shadow.shadowBlurRadius = 24 * s
  shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
  shadow.set()
  NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).setFill()
  tilePath.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(
    starting: NSColor(srgbRed: 0.20, green: 0.19, blue: 0.18, alpha: 1),
    ending: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1))!
    .draw(in: tilePath, angle: -90)

  // Inner blue-bordered badge, like the package tile in the reference.
  let badge = NSRect(x: 212 * s, y: 212 * s, width: 600 * s, height: 600 * s)
  let badgePath = NSBezierPath(roundedRect: badge, xRadius: 120 * s, yRadius: 120 * s)
  accent.withAlphaComponent(0.10).setFill()
  badgePath.fill()
  badgePath.lineWidth = 14 * s
  accent.setStroke()
  badgePath.stroke()

  // Monitor body.
  let screen = NSRect(x: 322 * s, y: 420 * s, width: 380 * s, height: 270 * s)
  let screenPath = NSBezierPath(roundedRect: screen, xRadius: 36 * s, yRadius: 36 * s)
  NSGradient(starting: accent, ending: accentDeep)!.draw(in: screenPath, angle: -90)

  // Stand.
  let stand = NSBezierPath()
  stand.lineWidth = 26 * s
  stand.lineCapStyle = .round
  stand.move(to: NSPoint(x: 512 * s, y: 420 * s)); stand.line(to: NSPoint(x: 512 * s, y: 350 * s))
  stand.move(to: NSPoint(x: 420 * s, y: 330 * s)); stand.line(to: NSPoint(x: 604 * s, y: 330 * s))
  accent.setStroke()
  stand.stroke()

  // ">_" prompt cut into the screen in tile color.
  let ink = NSColor(srgbRed: 0.14, green: 0.13, blue: 0.13, alpha: 1)
  let chevron = NSBezierPath()
  chevron.lineWidth = 30 * s
  chevron.lineCapStyle = .round
  chevron.lineJoinStyle = .round
  chevron.move(to: NSPoint(x: 392 * s, y: 610 * s))
  chevron.line(to: NSPoint(x: 462 * s, y: 555 * s))
  chevron.line(to: NSPoint(x: 392 * s, y: 500 * s))
  let cursor = NSBezierPath()
  cursor.lineWidth = 30 * s
  cursor.lineCapStyle = .round
  cursor.move(to: NSPoint(x: 512 * s, y: 500 * s)); cursor.line(to: NSPoint(x: 612 * s, y: 500 * s))
  ink.setStroke()
  chevron.stroke()
  cursor.stroke()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
  try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
