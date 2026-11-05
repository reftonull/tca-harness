// Example (macOS): record a live web page to H.264 by snapshotting an offscreen WKWebView.
// Works when no visible browser or screen recorder is available. Prints "START <epoch>" when
// frame 0 is captured, for aligning with other recordings.
// Usage: swiftc -O panel-recorder.swift -o panel-recorder
//        ./panel-recorder URL OUTPUT.mp4 SECONDS [SCRIPT_AT_SECONDS SCRIPT.js]
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
let width = 1280, height = 800, fps = 12.0

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height),
  styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
window.contentView = web
window.orderFrontRegardless()
web.load(URLRequest(url: url))

try? FileManager.default.removeItem(at: output)
let writer = try! AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
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
