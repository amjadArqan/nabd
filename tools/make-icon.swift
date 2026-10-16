// Draws Nabd's app icon and writes Nabd.icns plus docs/logo.png.  Run: swift tools/make-icon.swift
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt squircle centred on a 1024 pt canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.11, blue: 0.29), Color(red: 0.03, green: 0.05, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
            // Gauge: three quarters of a ring, cool cyan to hot orange.
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 52, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 560, height: 560)
            Circle().trim(from: 0, to: 0.75)
                .stroke(AngularGradient(colors: [Color(red: 0.02, green: 0.71, blue: 0.83), Color(red: 0.39, green: 0.40, blue: 0.95),
                                                 Color(red: 0.98, green: 0.45, blue: 0.09)],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 52, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 560, height: 560)
            // The pulse.
            Pulse()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 40, lineCap: .round, lineJoin: .round))
                .frame(width: 520, height: 300)
                .shadow(color: .white.opacity(0.45), radius: 18)
                .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Pulse: Shape {
    func path(in r: CGRect) -> Path {
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var path = Path()
        path.move(to: p(0, 0.55))
        path.addLine(to: p(0.28, 0.55))
        path.addLine(to: p(0.36, 0.40))
        path.addLine(to: p(0.45, 0.55))
        path.addLine(to: p(0.52, 0.0))
        path.addLine(to: p(0.62, 1.0))
        path.addLine(to: p(0.70, 0.55))
        path.addLine(to: p(1, 0.55))
        return path
    }
}

@MainActor func png(_ size: Int) -> Data {
    let renderer = ImageRenderer(content: Icon().scaleEffect(CGFloat(size) / 1024).frame(width: CGFloat(size), height: CGFloat(size)))
    renderer.scale = 1
    renderer.isOpaque = false
    let image = renderer.nsImage!
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Nabd.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        try! png(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try! fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)
    try! png(512).write(to: URL(fileURLWithPath: "docs/logo.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Nabd.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Nabd.icns and docs/logo.png" : "iconutil failed")
