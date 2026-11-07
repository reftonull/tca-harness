// Example (macOS, no ffmpeg needed): put two or more recordings side by side with AVFoundation.
// Each OFFSET is the second of that source that lines up with output t=0. A negative offset starts
// the source later (the pane is blank until then); a source that ends early holds its last frame.
// Usage: swift compose.swift VIDEO OFFSET VIDEO OFFSET [VIDEO OFFSET ...] DURATION OUTPUT.mp4
//   e.g. swift compose.swift panel.mp4 0 app.mp4 3.2 40 out.mp4
// Optional environment: COMPOSE_HEIGHT=1080 (pane height in pixels), COMPOSE_FPS=24,
// COMPOSE_LABELS="clean|buggy|panel" (a caption under each pane, "|"-separated),
// COMPOSE_TITLE="..." (a title bar above the panes),
// COMPOSE_BITRATE=8000000 (re-encode at this H.264 bit rate to bound the file size).
import AVFoundation
import CoreText
import QuartzCore

let a = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
let height = Double(env["COMPOSE_HEIGHT"] ?? "1080")!, gap = (16 * height / 1080).rounded()
let fps = Int32(env["COMPOSE_FPS"] ?? "24")!
let labels = env["COMPOSE_LABELS"].map { $0.components(separatedBy: "|") } ?? []
let title = env["COMPOSE_TITLE"] ?? ""
let labelBar = labels.isEmpty ? 0 : (height * 0.045).rounded(), titleBar = title.isEmpty ? 0 : (height * 0.06).rounded()
let pairs = stride(from: 1, to: a.count - 2, by: 2).map { (a[$0], Double(a[$0 + 1])!) }
let requested = Double(a[a.count - 2])!, outputPath = a[a.count - 1]
precondition(pairs.count >= 2 && (a.count - 3) % 2 == 0, "usage: VIDEO OFFSET VIDEO OFFSET [...] DURATION OUTPUT.mp4")

// Tracks do not retain their asset, so the assets stay referenced until export finishes.
var assets: [AVURLAsset] = []
func source(_ path: String) async throws -> (Double, AVAssetTrack, CGSize) {
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  assets.append(asset)
  let track = try await asset.loadTracks(withMediaType: .video)[0]
  let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
  return (try await track.load(.timeRange).end.seconds, track, CGSize(width: abs(size.width), height: abs(size.height)))
}
func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

let duration = time(requested)
let composition = AVMutableComposition()
var layers: [AVMutableVideoCompositionLayerInstruction] = []
var x = 0.0, centers: [Double] = []
for (path, offset) in pairs {
  let (end, track, size) = try await source(path)
  let scale = height / size.height, width = (size.width * scale).rounded()
  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
  // The part of the source inside the output: from max(offset, 0), placed at max(-offset, 0).
  let from = max(offset, 0), at = max(-offset, 0)
  let available = min(end - from, requested - at)
  precondition(available > 0, "\(path) has nothing between \(offset)s and its end (\(end)s)")
  try target.insertTimeRange(CMTimeRange(start: time(from), duration: time(available)), of: track, at: time(at))
  // Hold the last frame for the rest of the output.
  let filled = at + available
  if filled < requested - 0.01 {
    let frame = 1.0 / Double(max(try await track.load(.nominalFrameRate), 1))
    try target.insertTimeRange(CMTimeRange(start: time(end - frame), duration: time(frame)), of: track, at: time(filled))
    target.scaleTimeRange(CMTimeRange(start: time(filled), duration: time(frame)), toDuration: time(requested - filled))
  }
  let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: target)
  let transform = try await track.load(.preferredTransform)
  layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    .concatenating(CGAffineTransform(translationX: x, y: titleBar)), at: .zero)
  layers.append(layer)
  centers.append(x + width / 2)
  x += width + gap
}
let render = CGSize(width: ((x - gap) / 2).rounded() * 2, height: ((height + titleBar + labelBar) / 2).rounded() * 2)

let background = CGColor(red: 0.086, green: 0.094, blue: 0.153, alpha: 1)
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
instruction.layerInstructions = layers
instruction.backgroundColor = background
let video = AVMutableVideoComposition()
video.renderSize = render
video.frameDuration = CMTime(value: 1, timescale: fps)
video.instructions = [instruction]

if !labels.isEmpty || !title.isEmpty {
  // Core Animation layers use a bottom-left origin: the label bar is at y=0, the title bar on top.
  func text(_ string: String, size: Double, frame: CGRect, color: CGColor) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = string
    layer.font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
    layer.fontSize = size
    layer.foregroundColor = color
    layer.alignmentMode = .center
    layer.truncationMode = .end
    layer.contentsScale = 1
    layer.frame = frame
    layer.display()  // a command-line tool has no run loop to draw it later
    return layer
  }
  let parent = CALayer(), videoLayer = CALayer()
  parent.frame = CGRect(origin: .zero, size: render)
  parent.backgroundColor = background
  videoLayer.frame = parent.frame
  parent.addSublayer(videoLayer)
  let paneWidth = render.width / Double(max(pairs.count, 1))
  for (center, label) in zip(centers, labels) {
    let size = labelBar * 0.5
    parent.addSublayer(text(label, size: size, frame: CGRect(x: center - paneWidth / 2, y: (labelBar - size * 1.25) / 2,
      width: paneWidth, height: size * 1.3), color: CGColor(gray: 0.85, alpha: 1)))
  }
  if !title.isEmpty {
    let size = titleBar * 0.42
    parent.addSublayer(text(title, size: size, frame: CGRect(x: gap, y: render.height - titleBar + (titleBar - size * 1.25) / 2,
      width: render.width - 2 * gap, height: size * 1.3), color: CGColor(red: 0.66, green: 0.55, blue: 0.96, alpha: 1)))
  }
  video.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
}

let output = URL(fileURLWithPath: outputPath)
let bitrate = env["COMPOSE_BITRATE"].flatMap(Int.init)
let exported = bitrate == nil ? output : output.deletingPathExtension().appendingPathExtension("full.mp4")
try? FileManager.default.removeItem(at: exported)
let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
export.videoComposition = video
try await export.export(to: exported, as: .mp4)

if let bitrate {
  // Second pass: re-encode at a fixed bit rate (the export preset picks its own, often large).
  let asset = AVURLAsset(url: exported)
  let track = try await asset.loadTracks(withMediaType: .video)[0]
  let reader = try AVAssetReader(asset: asset)
  let readOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(readOutput)
  try? FileManager.default.removeItem(at: output)
  let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(render.width), AVVideoHeightKey: Int(render.height),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
  ])
  writer.add(input)
  reader.startReading()
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  while let sample = readOutput.copyNextSampleBuffer() {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    input.append(sample)
  }
  input.markAsFinished()
  await writer.finishWriting()
  if let error = writer.error { throw error }
  try FileManager.default.removeItem(at: exported)
}
print("wrote \(outputPath) \(Int(render.width))x\(Int(render.height))")
