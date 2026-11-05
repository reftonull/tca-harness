// Example (macOS, no ffprobe needed): print duration, size and frame rate; optionally save a frame.
// A recording with a frame rate near zero captured almost nothing (e.g. a hidden browser tab).
// Usage: swift inspect-video.swift VIDEO.mp4 [SECONDS FRAME.png]
import AVFoundation
import AppKit

let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let track = try await asset.loadTracks(withMediaType: .video).first
let size = try await track?.load(.naturalSize) ?? .zero
let fps = try await track?.load(.nominalFrameRate) ?? 0
print(String(format: "%.1fs %dx%d %.1f fps", try await asset.load(.duration).seconds, Int(size.width), Int(size.height), fps))
if a.count > 3 {
  let generator = AVAssetImageGenerator(asset: asset)
  generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
  let (image, _) = try await generator.image(at: CMTime(seconds: Double(a[2])!, preferredTimescale: 600))
  try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
  print("saved \(a[3])")
}
