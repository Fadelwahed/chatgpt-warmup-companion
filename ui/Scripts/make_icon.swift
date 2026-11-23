// Draws Warm-up's app icon: a sun rising over a horizon at dawn, with clock hands at 8:00 on the
// sun (the first warm-up of the day). Original geometry only; no SF Symbols (their license does
// not allow use in app icons).
// Usage: swift Scripts/make_icon.swift OUT.png   (1024 x 1024 PNG)
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift OUT.png\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(
        gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// macOS icon grid: an 824 pt rounded square centred in 1024, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x1B1F4B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Sky: night indigo at the top to dawn orange at the horizon.
linear(
    [rgb(0x1B1F4B), rgb(0x4B2C83), rgb(0xD9506A), rgb(0xFF9A3C)], [0, 0.42, 0.78, 1],
    from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 380))

// A few fading stars in the upper sky.
for (x, y, r, a) in [
    (250.0, 800.0, 7.0, 0.9), (360, 860, 4, 0.7), (720, 830, 6, 0.85), (820, 760, 4, 0.6), (600, 880, 3, 0.6),
] {
    ctx.setFillColor(rgb(0xFFFFFF, a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

let horizon: CGFloat = 372
let sunCenter = CGPoint(x: 512, y: horizon + 118)
let sunRadius: CGFloat = 178

// Glow and rays behind the sun.
let glow = CGGradient(
    colorsSpace: space, colors: [rgb(0xFFD27A, 0.75), rgb(0xFF9A3C, 0.0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(
    glow, startCenter: sunCenter, startRadius: sunRadius * 0.8, endCenter: sunCenter, endRadius: sunRadius * 2.1,
    options: [])
ctx.setStrokeColor(rgb(0xFFE3A3, 0.85))
ctx.setLineWidth(22)
ctx.setLineCap(.round)
for index in 0..<9 {
    let angle = CGFloat.pi * (0.08 + 0.84 * CGFloat(index) / 8)
    let inner = sunRadius + 42, outer = sunRadius + (index % 2 == 0 ? 120 : 92)
    ctx.move(to: CGPoint(x: sunCenter.x + cos(angle) * inner, y: sunCenter.y + sin(angle) * inner))
    ctx.addLine(to: CGPoint(x: sunCenter.x + cos(angle) * outer, y: sunCenter.y + sin(angle) * outer))
}
ctx.strokePath()

// The sun disc.
ctx.saveGState()
ctx.addEllipse(
    in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius))
ctx.clip()
linear(
    [rgb(0xFFF1C1), rgb(0xFFC85A), rgb(0xFF8A2B)], [0, 0.55, 1], from: CGPoint(x: 512, y: sunCenter.y + sunRadius),
    to: CGPoint(x: 512, y: sunCenter.y - sunRadius))
ctx.restoreGState()

// Clock hands at 8:00 on the sun.
ctx.setStrokeColor(rgb(0x5A2A1A, 0.9))
ctx.setLineCap(.round)
ctx.setLineWidth(26)
let minuteAngle = CGFloat.pi / 2  // 12 o'clock
ctx.move(to: sunCenter)
ctx.addLine(to: CGPoint(x: sunCenter.x + cos(minuteAngle) * 128, y: sunCenter.y + sin(minuteAngle) * 128))
ctx.strokePath()
ctx.setLineWidth(30)
let hourAngle = CGFloat.pi / 2 + 2 * CGFloat.pi * 4 / 12  // 8 o'clock
ctx.move(to: sunCenter)
ctx.addLine(to: CGPoint(x: sunCenter.x + cos(hourAngle) * 92, y: sunCenter.y + sin(hourAngle) * 92))
ctx.strokePath()
ctx.setFillColor(rgb(0x5A2A1A))
ctx.fillEllipse(in: CGRect(x: sunCenter.x - 22, y: sunCenter.y - 22, width: 44, height: 44))

// Land: two layered hills below the horizon.
ctx.setFillColor(rgb(0x2B1B4A))
ctx.move(to: CGPoint(x: 100, y: horizon + 30))
ctx.addCurve(
    to: CGPoint(x: 924, y: horizon - 10), control1: CGPoint(x: 360, y: horizon - 40),
    control2: CGPoint(x: 640, y: horizon + 70))
ctx.addLine(to: CGPoint(x: 924, y: 100))
ctx.addLine(to: CGPoint(x: 100, y: 100))
ctx.closePath()
ctx.fillPath()
ctx.setFillColor(rgb(0x1A1233))
ctx.move(to: CGPoint(x: 100, y: horizon - 70))
ctx.addCurve(
    to: CGPoint(x: 924, y: horizon - 110), control1: CGPoint(x: 420, y: horizon + 10),
    control2: CGPoint(x: 700, y: horizon - 160))
ctx.addLine(to: CGPoint(x: 924, y: 100))
ctx.addLine(to: CGPoint(x: 100, y: 100))
ctx.closePath()
ctx.fillPath()

// A subtle top highlight for depth.
linear([rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)], [0, 1], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 700))
ctx.restoreGState()

guard let image = ctx.makeImage(),
    let destination = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
