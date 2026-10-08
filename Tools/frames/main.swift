//
//  frames/main.swift
//  Pulls still frames out of a screen recording, for looking at what actually happened.
//  frames <video> <outdir> <start> <end> <fps> [cropX cropY cropW cropH as 0…1 fractions]
//

import AVFoundation
import AppKit

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let outDir = args[2]
let asset = AVURLAsset(url: url)
var crop: CGRect?
if args.count >= 10 {
    crop = CGRect(x: Double(args[6])!, y: Double(args[7])!, width: Double(args[8])!, height: Double(args[9])!)
}
let done = DispatchSemaphore(value: 0)
Task {
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    let start = Double(args[3])!, end = min(Double(args[4])!, duration), fps = Double(args[5])!
    print(String(format: "duration %.2fs", duration))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var t = start, i = 0
    while t <= end {
        if var image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
            if let crop, let cropped = image.cropping(to: CGRect(x: crop.minX * Double(image.width), y: crop.minY * Double(image.height),
                                                                width: crop.width * Double(image.width), height: crop.height * Double(image.height))) {
                image = cropped
            }
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? data?.write(to: URL(fileURLWithPath: String(format: "%@/f%03d_%06.2f.png", outDir, i, t)))
        }
        i += 1; t += 1 / fps
    }
    print("frames: \(i)")
    done.signal()
}
done.wait()
