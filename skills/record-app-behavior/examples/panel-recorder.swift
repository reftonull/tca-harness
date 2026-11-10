// Example (macOS): record a live web page to H.264 by snapshotting an offscreen WKWebView.
// Works when no visible browser or screen recorder is available. Prints "START <epoch>" when
// frame 0 is captured, for aligning with other recordings.
// Usage: swiftc -O panel-recorder.swift -o panel-recorder
//        ./panel-recorder URL OUTPUT.mp4 SECONDS [SCRIPT_AT_SECONDS SCRIPT.js]
// Optional environment: PANEL_SIZE=1280x800 (page size in points), PANEL_SCALE=2 (pixels per point,
// e.g. 2 for a Retina-sharp video on any display), PANEL_FPS=12, PANEL_STOP_FILE=/path (stop early
// when this file appears, like `flowdeck simulator record --stop-file`).
import AppKit
import AVFoundation
import WebKit

let args = CommandLine.arguments
let url = URL(string: args[1])!
let output = URL(fileURLWithPath: args[2])
let seconds = Double(args[3])!
// Optional page script (e.g. a captioned walkthrough) run once at a given time.
let tourAt = args.count > 5 ? Double(args[4])! : .infinity
let tour = args.count > 5 ? try! String(contentsOfFile: args[5], encoding: .utf8) : ""
let env = ProcessInfo.processInfo.environment
let size = (env["PANEL_SIZE"] ?? "1280x800").split(separator: "x").map { Int($0)! }
let points = (width: size[0], height: size[1])
let scale = Double(env["PANEL_SCALE"] ?? "1")!
let fps = Double(env["PANEL_FPS"] ?? "12")!
// Video pixels; WebKit renders the snapshot at this width, so text stays sharp rather than upscaled.
let width = Int(Double(points.width) * scale), height = Int(Double(points.height) * scale)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: points.width, height: points.height),
  styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: points.width, height: points.height))
window.contentView = web
window.orderFrontRegardless()
web.load(URLRequest(url: url))

try? FileManager.default.removeItem(at: output)
let writer = try! AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(6_000_000, width * height * 2)],
])
input.expectsMediaDataInRealTime = true
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
])
writer.add(input)

func buffer(_ image: CGImage) -> CVPixelBuffer? {
  var pb: CVPixelBuffer?
  guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }
  let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return pb
}

Task { @MainActor in
  try await Task.sleep(for: .seconds(2))  // page load and first poll
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  let start = Date()
  print("START", start.timeIntervalSince1970); fflush(stdout)
  var touring = false
  let config = WKSnapshotConfiguration()
  config.snapshotWidth = NSNumber(value: width)
  while true {
    let t = Date().timeIntervalSince(start)
    if t >= seconds { break }
    if let stop = env["PANEL_STOP_FILE"], FileManager.default.fileExists(atPath: stop) { break }
    if !touring && t >= tourAt {
      touring = true
      web.evaluateJavaScript(tour) { _, error in if let error { print("tour error", error) } }
    }
    if let image = try? await web.takeSnapshot(configuration: config),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      input.isReadyForMoreMediaData, let pb = buffer(cg) {
      adaptor.append(pb, withPresentationTime: CMTime(seconds: Date().timeIntervalSince(start), preferredTimescale: 600))
    }
    let next = (Double(Int(t * fps)) + 1) / fps
    let delay = next - Date().timeIntervalSince(start)
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
  }
  input.markAsFinished()
  await writer.finishWriting()
  print("DONE", writer.status.rawValue, writer.error.map { "\($0)" } ?? ""); fflush(stdout)
  exit(0)
}
app.run()
