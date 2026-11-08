import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.1, green: 0.13, blue: 0.23, alpha: 1).setFill(); background.fill()
NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.37, blue: 0.75, alpha: 0.6), ending: NSColor(calibratedRed: 0.1, green: 0.13, blue: 0.23, alpha: 0))!.draw(in: background, angle: -45)
let ring = NSBezierPath(ovalIn: NSRect(x: 246, y: 418, width: 310, height: 310))
ring.lineWidth = 72; NSColor(calibratedRed: 0.7, green: 0.92, blue: 0.83, alpha: 1).setStroke(); ring.stroke()
let stem = NSBezierPath(); stem.move(to: NSPoint(x: 499, y: 470)); stem.line(to: NSPoint(x: 732, y: 237))
stem.lineWidth = 72; stem.lineCapStyle = .round; stem.stroke()
let teeth = NSBezierPath(); teeth.move(to: NSPoint(x: 650, y: 319)); teeth.line(to: NSPoint(x: 718, y: 387)); teeth.move(to: NSPoint(x: 713, y: 256)); teeth.line(to: NSPoint(x: 780, y: 323))
teeth.lineWidth = 66; teeth.lineCapStyle = .round; teeth.stroke()
NSColor.white.withAlphaComponent(0.45).setFill()
NSBezierPath(roundedRect: NSRect(x: 265, y: 182, width: 245, height: 13), xRadius: 6, yRadius: 6).fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
