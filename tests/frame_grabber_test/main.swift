// Test program for IINA RAW's frame grabber (RawFrameGrabber/ in alperkaganavci/iina, branch iina-raw).
// tests/decoder_checks.sh (check_frame_grabber) compiles it together with RawFrameGrabber.swift
// and rawframe.c, and runs it:  frame_grabber_test <clip> <max pixel size> [fraction]
// It prints numbers only (size, mean luminance, info fields). It never writes or shows a picture.

import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
  print("FAIL: \(message)")
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3, let maxSize = Int(args[2]) else {
  fail("usage: frame_grabber_test <clip> <max pixel size> [fraction]")
}
let url = URL(fileURLWithPath: args[1])
let fraction = args.count > 3 ? Double(args[3]) ?? 0.1 : 0.1

let t0 = Date()
let image: CGImage
do {
  image = try grabFrame(url: url, maxPixelSize: maxSize, at: fraction)
} catch {
  fail("grabFrame: \(error.localizedDescription)")
}
let grabSeconds = Date().timeIntervalSince(t0)

// Mean luminance of the pixels, read back through a bitmap context (BGR0 -> RGBX).
let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
  fail("cannot create a bitmap context")
}
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
var total = 0.0
for i in 0..<(w * h) {
  total += 0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])
}
let mean = total / Double(w * h) / 255.0

let info: RawClipInfo
do {
  info = try clipInfo(url: url)
} catch {
  fail("clipInfo: \(error.localizedDescription)")
}

// A file that is not a tico_raw clip must give an error, not a crash.
var notRawFailed = false
do { _ = try grabFrame(url: URL(fileURLWithPath: "/etc/hosts"), maxPixelSize: 64) } catch { notRawFailed = true }

print(String(format: "grab %dx%d mean %.1f%% in %.2f s", w, h, mean * 100, grabSeconds))
print(String(format: "info %dx%d fps %.3f duration %.2f s codec '%@' iso %@ wb %@",
             info.width, info.height, info.fps, info.durationSeconds, info.codecLongName,
             info.iso.map { String($0) } ?? "none",
             info.whiteBalance.map { $0.map { String(format: "%.4f", $0) }.joined(separator: ",") } ?? "none"))
print("not-raw-file-error \(notRawFailed)")
print("color-space \(image.colorSpace?.name as String? ?? "none")")
