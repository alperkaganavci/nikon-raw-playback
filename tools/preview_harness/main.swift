// preview_harness: runs IINA RAW's Quick Look preview view controller (RawPreview/PreviewViewController.swift,
// compiled in) in a window that is never shown, and prints numbers only:
//   preview_harness <clip> <seconds>
// It waits for preparePreviewOfFile, lets the playback run, counts the frames put on the display
// layer, closes the preview (viewWillDisappear) and checks that the count stops. Output:
//   prepare: ok in <s> s | info: <text> | played: <n> frames in <s> s = <fps> fps | layer: <status>
//   after close: <n> frames (stopped=true|false) | rss: <MB>
// Then four tests of controller reuse, each on a fresh controller, with a clone of the clip
// (APFS clone, other name) as the second clip; each prints "<name>: ok" or "<name>: FAIL ...":
//   reuse        clip A plays, then prepare for clip B on the same controller: right after B's
//                prepare returns the video is hidden and the still is shown, one loop at most,
//                B plays (the URL is B), frames of A are gone from the layer.
//   stale        prepare A, then B at once: both handlers are called, A's late result is dropped,
//                only one loop runs and it plays B.
//   close        prepare A, then viewWillDisappear before the still decoded: the handler is
//                called, 0 loops, 0 frames, the result is dropped.
//   failed       A plays, then prepare for a file that does not exist: error, video hidden,
//                still shown, 0 loops.
//   pause        the pause hook stops the frames and the resume starts them again.

import Cocoa

let args = CommandLine.arguments
guard args.count == 3, let seconds = Double(args[2]) else {
  print("usage: preview_harness <clip> <seconds>")
  exit(2)
}
let url = URL(fileURLWithPath: args[1])

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let controller = PreviewViewController()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 572), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentViewController = controller

func rssMB() -> Double {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
  }
  return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

func spin(_ s: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }

var prepared: Error?? = .none
let t0 = Date()
controller.preparePreviewOfFile(at: url) { error in prepared = .some(error) }
while prepared == nil && Date().timeIntervalSince(t0) < 20 { spin(0.05) }
guard case .some(let error) = prepared, error == nil else {
  print("FAIL: preparePreviewOfFile \(String(describing: prepared))")
  exit(1)
}
let prepareSeconds = Date().timeIntervalSince(t0)
let label = controller.view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? "none"
let size = controller.preferredContentSize

let playStart = Date()
let framesBefore = controller.playbackFramesShown
spin(seconds)
let framesPlayed = controller.playbackFramesShown - framesBefore
let played = Date().timeIntervalSince(playStart)
let layerStatus = controller.playbackLayerStatus.rawValue
let visible = controller.playbackVideoVisible
let rssPlaying = rssMB()

controller.viewWillDisappear()
spin(0.3)
let atClose = controller.playbackFramesShown
spin(1.0)
let afterClose = controller.playbackFramesShown

print(String(format: "prepare: ok in %.2f s | info: %@ | content size: %.0fx%.0f", prepareSeconds, label, size.width, size.height))
print(String(format: "played: %d frames in %.2f s = %.1f fps | layer status: %d (2 = failed) | video visible: %@", framesPlayed, played, Double(framesPlayed) / played, layerStatus, visible ? "yes" : "no"))
print("after close: \(afterClose) frames (stopped=\(afterClose == atClose))")
print(String(format: "rss: %.0f MB", rssPlaying))


// ---- controller reuse ---------------------------------------------------------------------

var failures: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
  if !condition { failures.append("\(name): FAIL \(detail())") }
}

/// Call prepare and wait for its handler (up to 20 s). Returns the error, and whether it was called.
/// `inHandler` runs inside the handler, before the playback of this request can have started.
func prepareAndWait(_ c: PreviewViewController, _ url: URL, inHandler: @escaping () -> Void = {}) -> (called: Bool, error: Error?) {
  var result: (called: Bool, error: Error?) = (false, nil)
  c.preparePreviewOfFile(at: url) { error in inHandler(); result = (true, error) }
  let t = Date()
  while !result.called && Date().timeIntervalSince(t) < 20 { spin(0.02) }
  return result
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-harness-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let clipB = tmp.appendingPathComponent("clip-b.R3D")
// copyItem clones the file on APFS (no data is copied).
try FileManager.default.copyItem(at: url, to: clipB)

var windows: [NSWindow] = []

func freshController() -> PreviewViewController {
  let c = PreviewViewController()
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 572), styleMask: [.borderless], backing: .buffered, defer: false)
  w.contentViewController = c
  windows.append(w)
  return c
}

// reuse
do {
  let c = freshController()
  let a = prepareAndWait(c, url)
  check("reuse", a.called && a.error == nil, "prepare A: \(String(describing: a.error))")
  spin(1.5)
  check("reuse", c.playbackVideoVisible && c.playbackFramesShown > 10, "A did not play: visible \(c.playbackVideoVisible), frames \(c.playbackFramesShown)")
  let framesA = c.playbackFramesShown
  var inHandler = (video: true, still: false, loops: 99)
  let b = prepareAndWait(c, clipB) { inHandler = (c.playbackVideoVisible, c.playbackImageVisible, c.playbackActiveLoops) }
  check("reuse", b.called && b.error == nil, "prepare B: \(String(describing: b.error))")
  // When B's prepare returns: A's frame must be gone, B's still is up, and not more than one loop.
  check("reuse", !inHandler.video && inHandler.still, "in B's handler: video visible \(inHandler.video), still visible \(inHandler.still)")
  check("reuse", inHandler.loops <= 1, "loops in B's handler: \(inHandler.loops)")
  check("reuse", c.playbackURL == clipB, "URL is \(String(describing: c.playbackURL))")
  spin(1.5)
  check("reuse", c.playbackVideoVisible && c.playbackFramesShown > 10 && c.playbackActiveLoops == 1,
        "B did not play: visible \(c.playbackVideoVisible), frames \(c.playbackFramesShown), loops \(c.playbackActiveLoops)")
  check("reuse", framesA > 0, "frames of A: \(framesA)")
  c.viewWillDisappear()
  spin(0.5)
  check("reuse", c.playbackActiveLoops == 0, "loops after close: \(c.playbackActiveLoops)")
}
if !failures.contains(where: { $0.hasPrefix("reuse") }) { print("reuse: ok") }

// stale
do {
  let c = freshController()
  var doneA = false, doneB = false
  c.preparePreviewOfFile(at: url) { _ in doneA = true }
  c.preparePreviewOfFile(at: clipB) { _ in doneB = true }
  let t = Date()
  while !(doneA && doneB) && Date().timeIntervalSince(t) < 20 { spin(0.02) }
  check("stale", doneA && doneB, "handlers called: A \(doneA), B \(doneB)")
  check("stale", c.playbackDroppedCompletions == 1, "dropped completions: \(c.playbackDroppedCompletions), expected 1")
  spin(1.5)
  check("stale", c.playbackActiveLoops == 1, "active loops: \(c.playbackActiveLoops), expected 1")
  check("stale", c.playbackURL == clipB, "URL is \(String(describing: c.playbackURL)), expected clip B")
  check("stale", c.playbackFramesShown > 10, "frames: \(c.playbackFramesShown)")
  c.viewWillDisappear()
  spin(0.5)
}
if !failures.contains(where: { $0.hasPrefix("stale") }) { print("stale: ok") }

// close before the still decoded
do {
  let c = freshController()
  var done = false
  c.preparePreviewOfFile(at: url) { _ in done = true }
  c.viewWillDisappear()
  let t = Date()
  while !done && Date().timeIntervalSince(t) < 20 { spin(0.02) }
  spin(1.5)
  check("close", done, "handler was not called")
  check("close", c.playbackActiveLoops == 0 && c.playbackFramesShown == 0, "loops \(c.playbackActiveLoops), frames \(c.playbackFramesShown)")
  check("close", c.playbackDroppedCompletions == 1, "dropped completions: \(c.playbackDroppedCompletions), expected 1")
}
if !failures.contains(where: { $0.hasPrefix("close") }) { print("close: ok") }

// a clip that fails after one that played
do {
  let c = freshController()
  _ = prepareAndWait(c, url)
  spin(1.0)
  check("failed", c.playbackVideoVisible, "A did not play")
  let bad = prepareAndWait(c, tmp.appendingPathComponent("does-not-exist.R3D"))
  check("failed", bad.called && bad.error != nil, "no error for a missing file")
  spin(0.5)
  check("failed", !c.playbackVideoVisible && c.playbackImageVisible, "video visible \(c.playbackVideoVisible), still visible \(c.playbackImageVisible)")
  check("failed", c.playbackActiveLoops == 0, "loops \(c.playbackActiveLoops)")
  check("failed", c.view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "", "info line of the old clip is still shown")
}
if !failures.contains(where: { $0.hasPrefix("failed") }) { print("failed: ok") }

// pause while the window is not visible
do {
  let c = freshController()
  _ = prepareAndWait(c, url)
  spin(1.0)
  c.updatePaused(occluded: true)
  spin(0.3)
  let paused1 = c.playbackFramesShown
  spin(1.0)
  let paused2 = c.playbackFramesShown
  c.updatePaused(occluded: false)
  spin(1.0)
  let resumed = c.playbackFramesShown
  check("pause", paused1 == paused2 && c.playbackPaused == false && resumed > paused2 + 10,
        "frames while paused \(paused1) -> \(paused2), after resume \(resumed)")
  c.viewWillDisappear()
  spin(0.3)
}
if !failures.contains(where: { $0.hasPrefix("pause") }) { print("pause: ok") }

try? FileManager.default.removeItem(at: tmp)
for f in failures { print(f) }
print(failures.isEmpty ? "reuse-tests: ok" : "reuse-tests: FAIL")
exit(failures.isEmpty ? 0 : 1)
