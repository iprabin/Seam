// Draws the app icon: three edge-to-edge tiles, the focused one ringed in rainbow.
// Run `swift icon.swift` to regenerate icon.png (1024²); build.sh turns it into the .icns.
import AppKit

let s: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

// macOS icon grid: 824² body centred, corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [rgb(0.16, 0.17, 0.22), rgb(0.07, 0.07, 0.10)] as CFArray,
                                  locations: nil)!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// Tiles: big left, two stacked right, thin seams between them.
let inner = body.insetBy(dx: 120, dy: 120), seam: CGFloat = 14, r: CGFloat = 40
let leftW = (inner.width - seam) * 0.55
let left = CGRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
let rx = left.maxX + seam, rw = inner.maxX - rx, rh = (inner.height - seam) / 2
let top = CGRect(x: rx, y: inner.minY + rh + seam, width: rw, height: rh)
let bottom = CGRect(x: rx, y: inner.minY, width: rw, height: rh)
for t in [left, top, bottom] {
    ctx.addPath(CGPath(roundedRect: t, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(rgb(0.24, 0.25, 0.31)); ctx.fillPath()
}

// Rainbow ring round the focused (left) tile: conic gradient clipped to a stroke.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: left.insetBy(dx: 6, dy: 6), cornerWidth: r - 6, cornerHeight: r - 6, transform: nil))
ctx.setLineWidth(22); ctx.replacePathWithStrokedPath(); ctx.clip()
let c = CGPoint(x: left.midX, y: left.midY)
for i in 0..<360 {  // conic gradient as 360 one-degree wedges, hue by angle
    let a = CGFloat(i) * .pi / 180
    ctx.move(to: c)
    ctx.addArc(center: c, radius: s, startAngle: a, endAngle: a + .pi / 170, clockwise: false)
    ctx.setFillColor(NSColor(hue: CGFloat(i) / 360, saturation: 0.85, brightness: 1, alpha: 1).cgColor)
    ctx.fillPath()
}
ctx.restoreGState()

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon.png"))
