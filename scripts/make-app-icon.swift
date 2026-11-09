// Renders the app icon (blue tile, remote-desktop window + terminal window + sync badge) into
// an .iconset and a layered Photoshop file (one pixel layer per element, editable in Photoshop).
// Usage: swift scripts/make-app-icon.swift <outDir>
//   -> <outDir>/AppIcon.iconset, <outDir>/AppIcon.psd   then: iconutil -c icns <outDir>/AppIcon.iconset
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Design on a 1024 grid (AppKit coordinates, y up). Each layer draws itself at scale `s`.
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
func tilePath(_ s: CGFloat) -> NSBezierPath {
  NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
               xRadius: 185 * s, yRadius: 185 * s)
}
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: CGFloat) -> NSRect {
  NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
}
func dots(_ colors: [NSColor], x: CGFloat, y: CGFloat, _ s: CGFloat) {
  for (i, c) in colors.enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: r(x + CGFloat(i) * 38, y, 24, 24, s)).fill()
  }
}

let layers: [(name: String, draw: (CGFloat) -> Void)] = [
  ("Shadow", { s in
    let sh = NSShadow()
    sh.shadowColor = .black.withAlphaComponent(0.45)
    sh.shadowBlurRadius = 24 * s
    sh.shadowOffset = NSSize(width: 0, height: -10 * s)
    sh.set()
    rgb(0.04, 0.10, 0.30).setFill()
    tilePath(s).fill()
  }),
  ("Tile", { s in
    NSGradient(starting: rgb(0.22, 0.52, 1.00), ending: rgb(0.06, 0.16, 0.48))!
      .draw(in: tilePath(s), angle: -90)
  }),
  ("Gloss", { s in
    tilePath(s).addClip()
    NSGradient(starting: rgb(1, 1, 1, 0.22), ending: rgb(1, 1, 1, 0))!
      .draw(in: r(100, 512, 824, 412, s), angle: -90)
  }),
  ("Remote Desktop Window", { s in
    let win = NSBezierPath(roundedRect: r(318, 420, 486, 380, s), xRadius: 44 * s, yRadius: 44 * s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = .black.withAlphaComponent(0.30)
    sh.shadowBlurRadius = 30 * s
    sh.shadowOffset = NSSize(width: 0, height: -12 * s)
    sh.set()
    rgb(0.96, 0.97, 1.00).setFill()
    win.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Desktop area with a soft "wallpaper" and a hill.
    let screen = NSBezierPath(roundedRect: r(342, 444, 438, 286, s), xRadius: 26 * s, yRadius: 26 * s)
    NSGradient(starting: rgb(0.55, 0.78, 1.00), ending: rgb(0.27, 0.55, 0.98))!
      .draw(in: screen, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    let hill = NSBezierPath()
    hill.move(to: NSPoint(x: 342 * s, y: 540 * s))
    hill.curve(to: NSPoint(x: 780 * s, y: 600 * s),
               controlPoint1: NSPoint(x: 500 * s, y: 640 * s), controlPoint2: NSPoint(x: 640 * s, y: 520 * s))
    hill.line(to: NSPoint(x: 780 * s, y: 444 * s)); hill.line(to: NSPoint(x: 342 * s, y: 444 * s)); hill.close()
    rgb(0.18, 0.42, 0.92, 0.85).setFill()
    hill.fill()
    rgb(1, 1, 1, 0.9).setFill()
    NSBezierPath(ovalIn: r(690, 650, 50, 50, s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    dots([rgb(1.00, 0.37, 0.34), rgb(1.00, 0.74, 0.18), rgb(0.16, 0.79, 0.25)], x: 350, y: 752, s)
  }),
  ("Terminal Window", { s in
    let win = NSBezierPath(roundedRect: r(220, 236, 430, 316, s), xRadius: 40 * s, yRadius: 40 * s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = .black.withAlphaComponent(0.45)
    sh.shadowBlurRadius = 36 * s
    sh.shadowOffset = NSSize(width: 0, height: -16 * s)
    sh.set()
    NSGradient(starting: rgb(0.13, 0.15, 0.21), ending: rgb(0.06, 0.07, 0.11))!.draw(in: win, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    win.lineWidth = 3 * s
    rgb(1, 1, 1, 0.12).setStroke()
    win.stroke()
    dots([rgb(1, 1, 1, 0.28), rgb(1, 1, 1, 0.28), rgb(1, 1, 1, 0.28)], x: 250, y: 500, s)
    // ">_" prompt.
    let ink = rgb(0.33, 0.95, 0.72)
    let chevron = NSBezierPath()
    chevron.lineWidth = 32 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 284 * s, y: 448 * s))
    chevron.line(to: NSPoint(x: 352 * s, y: 393 * s))
    chevron.line(to: NSPoint(x: 284 * s, y: 338 * s))
    chevron.move(to: NSPoint(x: 400 * s, y: 330 * s))
    chevron.line(to: NSPoint(x: 492 * s, y: 330 * s))
    ink.setStroke()
    chevron.stroke()
  }),
  ("Sync Badge", { s in
    let disc = NSBezierPath(ovalIn: r(636, 196, 196, 196, s))
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = .black.withAlphaComponent(0.35)
    sh.shadowBlurRadius = 24 * s
    sh.shadowOffset = NSSize(width: 0, height: -8 * s)
    sh.set()
    rgb(1, 1, 1).setFill()
    disc.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Two opposing arrows (⇄): connection both ways.
    let blue = rgb(0.12, 0.40, 0.98)
    let p = NSBezierPath()
    p.lineWidth = 22 * s
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 690 * s, y: 322 * s)); p.line(to: NSPoint(x: 776 * s, y: 322 * s))
    p.move(to: NSPoint(x: 746 * s, y: 350 * s)); p.line(to: NSPoint(x: 776 * s, y: 322 * s))
    p.line(to: NSPoint(x: 746 * s, y: 294 * s))
    p.move(to: NSPoint(x: 778 * s, y: 266 * s)); p.line(to: NSPoint(x: 692 * s, y: 266 * s))
    p.move(to: NSPoint(x: 722 * s, y: 294 * s)); p.line(to: NSPoint(x: 692 * s, y: 266 * s))
    p.line(to: NSPoint(x: 722 * s, y: 238 * s))
    blue.setStroke()
    p.stroke()
  }),
]

func render(_ px: Int, _ draws: [(CGFloat) -> Void]) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  for d in draws {
    NSGraphicsContext.saveGraphicsState()
    d(CGFloat(px) / 1024)
    NSGraphicsContext.restoreGraphicsState()
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

// MARK: - Minimal layered PSD writer (8-bit RGB, PackBits-compressed channels).

struct Planes { var top = 0, left = 0, bottom = 0, right = 0; var ch: [[UInt8]] = [] }  // R,G,B,A

/// Un-premultiplies the rep and returns R,G,B,A planes cropped to the opaque bounds (or full size).
func planes(_ rep: NSBitmapImageRep, crop: Bool) -> Planes {
  let w = rep.pixelsWide, h = rep.pixelsHigh, bpr = rep.bytesPerRow, d = rep.bitmapData!
  var t = 0, l = 0, b = h, rt = w
  if crop {
    t = h; l = w; b = 0; rt = 0
    for y in 0..<h { for x in 0..<w where d[y * bpr + x * 4 + 3] != 0 {
      t = min(t, y); b = max(b, y + 1); l = min(l, x); rt = max(rt, x + 1)
    } }
    if b <= t { t = 0; l = 0; b = 0; rt = 0 }
  }
  var p = Planes(top: t, left: l, bottom: b, right: rt, ch: Array(repeating: [], count: 4))
  for y in t..<b { for x in l..<rt {
    let i = y * bpr + x * 4, a = Int(d[i + 3])
    for c in 0..<3 { p.ch[c].append(a == 0 ? 0 : UInt8(min(255, (Int(d[i + c]) * 255 + a / 2) / a))) }
    p.ch[3].append(UInt8(a))
  } }
  return p
}

func packBits(_ src: ArraySlice<UInt8>) -> [UInt8] {
  var out: [UInt8] = [], i = src.startIndex
  let end = src.endIndex
  while i < end {
    var run = 1
    while i + run < end && run < 128 && src[i + run] == src[i] { run += 1 }
    if run > 1 { out += [UInt8(bitPattern: Int8(1 - run)), src[i]]; i += run; continue }
    var j = i
    while j < end && j - i < 128 && !(j + 1 < end && src[j] == src[j + 1]) { j += 1 }
    out.append(UInt8(j - i - 1)); out += src[i..<j]; i = j
  }
  return out
}

/// Channel payload: [counts per row (u16)] + [packed rows]. Compression marker is written by caller.
func rle(_ plane: [UInt8], w: Int, h: Int) -> [UInt8] {
  var counts: [UInt8] = [], body: [UInt8] = []
  for y in 0..<h {
    let row = packBits(plane[(y * w)..<(y * w + w)])
    counts += [UInt8(row.count >> 8), UInt8(row.count & 0xFF)]
    body += row
  }
  return counts + body
}

extension Data {
  mutating func u16(_ v: Int) { append(contentsOf: [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
  mutating func u32(_ v: Int) { append(contentsOf: (0..<4).map { UInt8((v >> (24 - $0 * 8)) & 0xFF) }) }
}

func psd(size: Int, layers: [(String, Planes)], composite: Planes) -> Data {
  var f = Data("8BPS".utf8)
  f.u16(1); f.append(Data(count: 6)); f.u16(4); f.u32(size); f.u32(size); f.u16(8); f.u16(3)
  f.u32(0); f.u32(0)  // color mode data, image resources

  var records = Data(), pixels = Data()
  for (name, p) in layers {
    let w = p.right - p.left, h = p.bottom - p.top
    records.u32(p.top); records.u32(p.left); records.u32(p.bottom); records.u32(p.right)
    records.u16(4)
    var chans: [(Int, [UInt8])] = []
    for (id, c) in [(-1, 3), (0, 0), (1, 1), (2, 2)] { chans.append((id, rle(p.ch[c], w: w, h: h))) }
    for (id, payload) in chans {
      records.u16(id & 0xFFFF); records.u32(2 + payload.count)
      pixels.u16(1); pixels.append(contentsOf: payload)
    }
    records.append(Data("8BIMnorm".utf8)); records.append(contentsOf: [255, 0, 0, 0])
    var pname = Data([UInt8(name.utf8.count)] + Array(name.utf8))
    while pname.count % 4 != 0 { pname.append(0) }
    records.u32(8 + pname.count); records.u32(0); records.u32(0); records.append(pname)
  }
  var layerInfo = Data()
  layerInfo.u16((-layers.count) & 0xFFFF)  // negative: merged image carries transparency
  layerInfo.append(records); layerInfo.append(pixels)
  if layerInfo.count % 2 != 0 { layerInfo.append(0) }
  f.u32(4 + layerInfo.count + 4); f.u32(layerInfo.count); f.append(layerInfo); f.u32(0)

  // Merged image: RLE, all row counts for every channel first, then all rows.
  f.u16(1)
  let packed = [0, 1, 2, 3].map { c in
    (0..<size).map { y in packBits(composite.ch[c][(y * size)..<(y * size + size)]) }
  }
  for rows in packed { for row in rows { f.u16(row.count) } }
  for rows in packed { for row in rows { f.append(contentsOf: row) } }
  return f
}

// MARK: - Main

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let all = layers.map(\.draw)
for base in [16, 32, 128, 256, 512] {
  for (scale, suffix) in [(1, ""), (2, "@2x")] {
    try render(base * scale, all).representation(using: .png, properties: [:])!
      .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
  }
}
let psdLayers = layers.map { ($0.name, planes(render(1024, [$0.draw]), crop: true)) }
try psd(size: 1024, layers: psdLayers, composite: planes(render(1024, all), crop: false))
  .write(to: outDir.appendingPathComponent("AppIcon.psd"))
