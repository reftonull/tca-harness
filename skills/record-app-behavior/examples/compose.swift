// Example (macOS, no ffmpeg needed): put two recordings side by side with AVFoundation.
// LEFT_OFFSET/RIGHT_OFFSET are the seconds into each source that line up with output t=0.
// Usage: swift compose.swift LEFT.mp4 LEFT_OFFSET RIGHT.mp4 RIGHT_OFFSET DURATION OUTPUT.mp4
import AVFoundation

let a = CommandLine.arguments
let height = 1080.0, gap = 16.0
// Tracks do not retain their asset, so the assets stay referenced until export finishes.
var assets: [AVURLAsset] = []
func source(_ path: String) async throws -> (Double, AVAssetTrack, CGSize) {
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  assets.append(asset)
  let track = try await asset.loadTracks(withMediaType: .video)[0]
  let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
  return (try await track.load(.timeRange).end.seconds, track, CGSize(width: abs(size.width), height: abs(size.height)))
}
let (leftEnd, leftTrack, leftSize) = try await source(a[1])
let (rightEnd, rightTrack, rightSize) = try await source(a[3])
// Inserting past the end of either source makes the export fail, so clamp to what both have.
let seconds = min(Double(a[5])!, leftEnd - Double(a[2])!, rightEnd - Double(a[4])!)
let duration = CMTime(seconds: seconds, preferredTimescale: 600)
let leftScale = height / leftSize.height, rightScale = height / rightSize.height
let leftWidth = (leftSize.width * leftScale).rounded(), rightWidth = (rightSize.width * rightScale).rounded()
let render = CGSize(width: ((leftWidth + gap + rightWidth) / 2).rounded() * 2, height: height)

let composition = AVMutableComposition()
var layers: [AVMutableVideoCompositionLayerInstruction] = []
for (track, offset, scale, x) in [(leftTrack, Double(a[2])!, leftScale, 0.0), (rightTrack, Double(a[4])!, rightScale, leftWidth + gap)] {
  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
  try target.insertTimeRange(CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600), duration: duration), of: track, at: .zero)
  let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: target)
  let transform = try await track.load(.preferredTransform)
  layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: x, y: 0)), at: .zero)
  layers.append(layer)
}
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
instruction.layerInstructions = layers
instruction.backgroundColor = CGColor(red: 0.086, green: 0.094, blue: 0.153, alpha: 1)
let video = AVMutableVideoComposition()
video.renderSize = render
video.frameDuration = CMTime(value: 1, timescale: 24)
video.instructions = [instruction]
let output = URL(fileURLWithPath: a[6])
try? FileManager.default.removeItem(at: output)
let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
export.videoComposition = video
try await export.export(to: output, as: .mp4)
print("wrote \(a[6]) \(Int(render.width))x\(Int(render.height))")
