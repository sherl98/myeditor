import AppKit
import SwiftUI
import zlib

// Repack PNG's existing scanline bytes at zlib level 9. Pixels, PNG filters and
// color metadata stay byte-for-byte identical; only the compressed stream changes.
func losslessPNG(_ png: Data, pixels: Int) -> Data {
    guard png[24] == 8, png[25] == 6, png[28] == 0 else { return png }
    var chunks: [(type: String, data: Data)] = []
    var compressed = Data()
    var offset = 8
    while offset + 12 <= png.count {
        let length = png[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
        let end = offset + length + 12
        guard end <= png.count else { return png }
        chunks.append((type, png.subdata(in: offset..<end)))
        if type == "IDAT" { compressed.append(png.subdata(in: offset + 8..<end - 4)) }
        offset = end
    }
    var rawLength = uLongf((pixels * 4 + 1) * pixels)
    var raw = [UInt8](repeating: 0, count: Int(rawLength))
    let decoded = compressed.withUnsafeBytes { source in
        raw.withUnsafeMutableBufferPointer { destination in
            uncompress(
                destination.baseAddress!, &rawLength,
                source.bindMemory(to: UInt8.self).baseAddress!, uLong(compressed.count))
        }
    }
    guard decoded == Z_OK else { return png }
    var length = compressBound(uLong(rawLength))
    var packed = [UInt8](repeating: 0, count: Int(length))
    let encoded = raw.withUnsafeBufferPointer { source in
        packed.withUnsafeMutableBufferPointer { destination in
            compress2(
                destination.baseAddress!, &length, source.baseAddress!, uLong(rawLength),
                Z_BEST_COMPRESSION)
        }
    }
    guard encoded == Z_OK, length < compressed.count else { return png }
    let payload = Data(packed.prefix(Int(length)))
    let tagged = Data("IDAT".utf8) + payload
    let checksum = tagged.withUnsafeBytes {
        crc32(0, $0.bindMemory(to: UInt8.self).baseAddress!, uInt(tagged.count))
    }
    let chunk = bigEndian(UInt32(payload.count)) + tagged + bigEndian(UInt32(checksum))
    var output = Data(png.prefix(8))
    var inserted = false
    for entry in chunks {
        if entry.type == "IDAT" {
            if !inserted {
                output.append(chunk)
                inserted = true
            }
        } else {
            output.append(entry.data)
        }
    }
    return output
}

// The supplied artwork is unchanged. Only its outer mask and transparent margin
// adapt it to the shared macOS Dock footprint. NSImage renders the SVG natively.
guard CommandLine.arguments.count == 4,
    let artwork = NSImage(contentsOfFile: CommandLine.arguments[1])
else {
    fatalError("Usage: MakeIcon.swift source.svg destination.iconset destination.icns")
}
artwork.cacheMode = .never
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.clear(
            CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let mask = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile)
        NSGraphicsContext.current?.cgContext.addPath(mask.cgPath)
        NSGraphicsContext.current?.cgContext.clip()
        artwork.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let png = losslessPNG(bitmap.representation(using: .png, properties: [:])!, pixels: pixels)
        try png.write(to: destination.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

// ICNS is a container of standard PNG representations. Encoding it here also
// works on build hosts without access to the IconServices conversion daemon.
func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let representations = [
    ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"),
]
var chunks = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: destination.appendingPathComponent(name))
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(UInt32(png.count + 8)))
    chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(UInt32(chunks.count + 8)))
icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
