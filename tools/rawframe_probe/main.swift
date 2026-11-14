// rawframe_probe: command-line harness for IINA RAW's frame grabber (RawFrameGrabber/ in
// alperkaganavci/iina, branch iina-raw). tests/decoder_checks.sh builds it with the same sources as the Quick Look
// extensions. It prints numbers and the info line only; it never shows or writes a picture.
//
//   rawframe_probe <clip> thumb     one thumbnail request:  grabFrame, long side 512
//   rawframe_probe <clip> preview   one preview request:    grabFrameAndInfo, long side 1920
//   rawframe_probe <clip> play [s] play for s seconds (default 6) at full speed (RawClipPlayer, long
//                                   side 1280), print frames and frames per second
//   rawframe_probe <clip> selftest  scale synthetic frames of changing size and pixel format with one
//                                   scaler (the guard against a scaler built for another frame)
//   rawframe_probe <clip> format    feed the info-line formatting inf, NaN, -1, 1e300 (must not crash)
//
// Output lines: "image: <w>x<h>", "info-line: ...", "duration: <seconds>".

import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, args.count <= 4, ["thumb", "preview", "format", "play", "selftest"].contains(args[2]) else {
  print("usage: rawframe_probe <clip> thumb|preview|format|play|selftest [seconds]")
  exit(2)
}
let url = URL(fileURLWithPath: args[1])

if args[2] == "selftest" {
  do {
    try rawFrameSelfTestScale()
    print("selftest: ok")
    exit(0)
  } catch {
    print("selftest: FAIL \(error.localizedDescription)")
    exit(1)
  }
}

if args[2] == "format" {
  // Damaged values must give a line without the field, and never trap.
  let bad: [Double] = [.infinity, -.infinity, .nan, -1, 0, 1e300, 86_400, 1e19, 0.4]
  for value in bad {
    let info = RawClipInfo(width: 3030, height: 1705, fps: value, durationSeconds: value,
                           codecLongName: "x", iso: nil, whiteBalance: nil)
    print("format \(value): \(info.previewLine)")
  }
  // A frame rate below 0.001 would print as "0 fps": the field is left out.
  let tiny = RawClipInfo(width: 3030, height: 1705, fps: 0.0004, durationSeconds: 0,
                         codecLongName: "x", iso: nil, whiteBalance: nil)
  print("format fps0.0004: \(tiny.previewLine)")
  let ok = RawClipInfo(width: 3030, height: 1705, fps: 23.976, durationSeconds: 32.76,
                       codecLongName: "x", iso: 800, whiteBalance: nil)
  print("format ok: \(ok.previewLine)")
  exit(0)
}

if args[2] == "play" {
  let seconds = args.count > 3 ? Double(args[3]) ?? 6 : 6
  do {
    let player = try RawClipPlayer(url: url, maxPixelSize: 1280)
    let stride = player.width * 4
    var buffer = [UInt8](repeating: 0, count: stride * player.height)
    let start = Date()
    var frames = 0
    var firstSum = 0, lastSum = 0
    try buffer.withUnsafeMutableBytes { raw in
      while Date().timeIntervalSince(start) < seconds {
        try player.nextFrame(into: raw.baseAddress!, bytesPerRow: stride)
        frames += 1
        if frames == 1 { firstSum = raw.prefix(4096).reduce(0) { $0 + Int($1) } }
        lastSum = raw.prefix(4096).reduce(0) { $0 + Int($1) }
      }
    }
    let elapsed = Date().timeIntervalSince(start)
    print("play: \(player.width)x\(player.height), \(frames) frames in \(String(format: "%.2f", elapsed)) s = \(String(format: "%.1f", Double(frames) / elapsed)) fps (clip has \(Int(player.info.durationSeconds * player.info.fps)) frames)")
    _ = (firstSum, lastSum)
  } catch {
    print("FAIL: \(error.localizedDescription)")
    exit(1)
  }
  exit(0)
}

do {
  if args[2] == "thumb" {
    let image = try grabFrame(url: url, maxPixelSize: 512, at: 0.1)
    print("image: \(image.width)x\(image.height)")
  } else {
    let (image, info) = try grabFrameAndInfo(url: url, maxPixelSize: 1920, at: 0.1)
    print("image: \(image.width)x\(image.height)")
    print("info-line: \(info.previewLine)")
    print("duration: \(info.durationSeconds)")
  }
} catch {
  print("FAIL: \(error.localizedDescription)")
  exit(1)
}
