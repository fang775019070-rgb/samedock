import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let set = root.appendingPathComponent("Docklune.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size) / 1024
    let t = NSAffineTransform(); t.scale(by: s); t.concat()
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 65,y:65,width:894,height:894), xRadius:210, yRadius:210).fill()
    NSColor(calibratedRed:0.30,green:0.48,blue:0.99,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:220,y:390,width:600,height:400),xRadius:70,yRadius:70).fill()
    NSColor(calibratedRed:0.09,green:0.20,blue:0.62,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:170,y:230,width:520,height:360),xRadius:60,yRadius:60).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect:NSRect(x:230,y:290,width:400,height:235),xRadius:26,yRadius:26).fill()
    NSColor(calibratedRed:0.30,green:0.48,blue:0.99,alpha:1).setFill()
    for x in [290,395,500] { NSBezierPath(roundedRect:NSRect(x:x,y:320,width:65,height:45),xRadius:12,yRadius:12).fill() }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
    let data = bitmap.representation(using:.png,properties:[:])!
    if size == 1024 { try data.write(to: root.appendingPathComponent("AppIcon.png")) }
    if size <= 512 { try data.write(to:set.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to:set.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
