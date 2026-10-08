import AppKit
let out = CommandLine.arguments[1]
let cols = Int(CommandLine.arguments[2])!
let cellW = CGFloat(Double(CommandLine.arguments[3])!)
let files = Array(CommandLine.arguments.dropFirst(4))
guard let first = NSImage(contentsOfFile: files[0]) else { exit(1) }
let aspect = first.size.height / first.size.width
let cellH = (cellW * aspect).rounded()
let rows = Int(ceil(Double(files.count) / Double(cols)))
let size = NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows))
let image = NSImage(size: size)
image.lockFocus()
NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
for (i, f) in files.enumerated() {
    guard let img = NSImage(contentsOfFile: f) else { continue }
    let c = CGFloat(i % cols), r = CGFloat(i / cols)
    img.draw(in: NSRect(x: c * cellW, y: size.height - (r + 1) * cellH, width: cellW, height: cellH))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
