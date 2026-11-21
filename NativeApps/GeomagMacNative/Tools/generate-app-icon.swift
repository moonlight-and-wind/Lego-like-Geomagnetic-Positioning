import AppKit
import Foundation

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext

let graphite = NSColor(
    calibratedRed: 0.0549,
    green: 0.0706,
    blue: 0.0941,
    alpha: 1
)
context.setFillColor(graphite.cgColor)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

context.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
context.setLineWidth(2)
for index in 1..<12 {
    let position = CGFloat(index) * CGFloat(size) / 12
    context.move(to: CGPoint(x: position, y: 0))
    context.addLine(to: CGPoint(x: position, y: CGFloat(size)))
    context.move(to: CGPoint(x: 0, y: position))
    context.addLine(to: CGPoint(x: CGFloat(size), y: position))
}
context.strokePath()

let route = [
    CGPoint(x: 280, y: 280),
    CGPoint(x: 280, y: 760),
    CGPoint(x: 760, y: 760),
    CGPoint(x: 760, y: 320),
]
let paper = NSColor(
    calibratedRed: 0.9490,
    green: 0.9412,
    blue: 0.9098,
    alpha: 1
)
context.setStrokeColor(paper.cgColor)
context.setLineWidth(46)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: route[0])
for point in route.dropFirst() {
    context.addLine(to: point)
}
context.strokePath()

let signal = NSColor(
    calibratedRed: 0.0392,
    green: 0.3490,
    blue: 0.9686,
    alpha: 1
)
let trace = NSColor(
    calibratedRed: 0.3608,
    green: 0.9490,
    blue: 0.7804,
    alpha: 1
)
for (point, color) in [(route[0], signal), (route[3], trace)] {
    let dot = CGRect(
        x: point.x - 42,
        y: point.y - 42,
        width: 84,
        height: 84
    )
    context.setFillColor(graphite.cgColor)
    context.fillEllipse(in: dot.insetBy(dx: -12, dy: -12))
    context.setFillColor(color.cgColor)
    context.fillEllipse(in: dot)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon PNG\n", stderr)
    exit(1)
}
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/AppIcon-1024.png"
try data.write(to: URL(fileURLWithPath: output), options: .atomic)
print(output)
