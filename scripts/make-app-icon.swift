// Builds Herdly's AppIcon.icns from the code-drawn mark, so the repository keeps no icon binaries.
// scripts/build-app.sh compiles it together with Sources/HerdlyApp/HerdlyMark.swift:
//   swiftc -parse-as-library -o <tool> Sources/HerdlyApp/HerdlyMark.swift scripts/make-app-icon.swift
//   <tool> <output.icns>
// Optional second argument: a directory to also receive a 1024 px PNG preview.
import AppKit

@main
struct MakeAppIcon {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: make-app-icon <output.icns> [preview-dir]\n".utf8))
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[1])
        let iconset = FileManager.default.temporaryDirectory
            .appendingPathComponent("Herdly-\(ProcessInfo.processInfo.globallyUniqueString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for points in [16, 32, 128, 256, 512] {
            try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
            try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
        if arguments.count >= 3 {
            try png(pixels: 1024).write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("herdly-app-icon-1024.png"))
        }
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("make-app-icon: iconutil failed\n".utf8))
            exit(1)
        }
    }

    private static func png(pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        HerdlyMark.drawAppIcon(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
