// Fallback for check_ql_thumbnail when "qlmanage -t" does not return (it hangs when there is
// no window server). It asks the same service as Finder (QLThumbnailGenerator) for a
// thumbnail only (no generic icon), and writes it as a PNG:  ql_thumbnail_test <clip> <size> <out.png>
// Numbers only: the picture is never shown.

import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let size = Double(args[2]) else {
  print("usage: ql_thumbnail_test <clip> <size> <out.png>")
  exit(2)
}
let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: args[1]),
                                           size: CGSize(width: size, height: size), scale: 1,
                                           representationTypes: .thumbnail)
let done = DispatchSemaphore(value: 0)
var status: Int32 = 1
QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
  defer { done.signal() }
  guard let representation = representation else {
    print("no thumbnail: \(error.map { String(describing: $0) } ?? "unknown error")")
    return
  }
  let url = URL(fileURLWithPath: args[3]) as CFURL
  guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    print("cannot create the PNG file")
    return
  }
  CGImageDestinationAddImage(destination, representation.cgImage, nil)
  if CGImageDestinationFinalize(destination) { status = 0 } else { print("cannot write the PNG file") }
}
if done.wait(timeout: .now() + 30) == .timedOut { print("timeout: no answer from the thumbnail service") }
exit(status)
