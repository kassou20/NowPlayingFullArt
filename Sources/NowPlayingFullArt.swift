// NowPlayingFullArt — Plexamp edition
// Hooks MPNowPlayingInfoCenter to inject MPMediaItemAnimatedArtwork so the
// Lock Screen shows full-bleed album art with Liquid Glass on iOS 26.
//
// Architecture:
//   bootstrap.c  → __attribute__((constructor)) queues npa_bootstrap on main
//   This file     → npa_bootstrap() swizzles -[MPNowPlayingInfoCenter setNowPlayingInfo:]
//                   On every call it composites a 3:4 portrait preview, renders a
//                   short zoom-loop H.264 video, and attaches both via the new
//                   MPMediaItemAnimatedArtwork API.

import Foundation
import UIKit
import MediaPlayer
import AVFoundation
import CoreImage
import ObjectiveC

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Config
// ─────────────────────────────────────────────────────────────────────────────

private enum NPAConfig {
    /// Set false for a cheaper two-frame still that still fills the screen.
    static let animate        = true
    /// Length of the zoom loop in seconds.
    static let loopSeconds    = 3.0
    /// Zoom amplitude — 0.05 → 5 % scale swing, with zero velocity at the seam.
    static let zoomAmplitude  = 0.05
    /// Preview image size (3:4 ratio mandatory — system discards other ratios).
    static let previewSize    = CGSize(width: 900, height: 1200)
    /// Encoded video size (3:4 ratio mandatory).
    static let videoSize      = CGSize(width: 720, height: 960)
    /// Video frame rate.
    static let fps            = 30
    /// Maximum cached videos on disk before pruning oldest.
    static let maxCachedFiles = 20
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Artwork Composer (static image → 3:4 portrait)
// ─────────────────────────────────────────────────────────────────────────────

private final class ArtworkComposer {

    /// Builds a 3:4 portrait from a square cover: blurred + dimmed background
    /// with the original cover centered on top.
    static func compose(cover: UIImage, outputSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: outputSize)

            // 1. Draw cover stretched to fill the whole 3:4 canvas (will be blurred)
            cover.draw(in: rect)

            // 2. Apply gaussian blur via CIFilter
            if let ciImage = CIImage(image: renderer.image { c in cover.draw(in: rect) }),
               let blur = CIFilter(name: "CIGaussianBlur", parameters: [
                   kCIInputImageKey: ciImage,
                   kCIInputRadiusKey: 40
               ]),
               let output = blur.outputImage {
                let ciCtx = CIContext()
                if let cgBlurred = ciCtx.createCGImage(output, from: ciImage.extent) {
                    UIImage(cgImage: cgBlurred).draw(in: rect)
                }
            }

            // 3. Dim overlay so the foreground pops
            UIColor.black.withAlphaComponent(0.3).setFill()
            ctx.fill(rect)

            // 4. Center the original cover, scaled to fit width with padding
            let padding: CGFloat = outputSize.width * 0.05
            let coverWidth = outputSize.width - padding * 2
            let coverHeight = coverWidth // square
            let coverY = (outputSize.height - coverHeight) / 2
            let coverRect = CGRect(x: padding, y: coverY, width: coverWidth, height: coverHeight)
            cover.draw(in: coverRect)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Video Maker (image → H.264 zoom loop)
// ─────────────────────────────────────────────────────────────────────────────

private final class VideoMaker {

    /// Renders a looping zoom video from a portrait image.
    /// The zoom eases in and out with a cosine wave so the loop seam is invisible.
    static func render(image: UIImage,
                       to outputURL: URL,
                       size: CGSize,
                       duration: Double,
                       fps: Int,
                       amplitude: Double,
                       completion: @escaping (Bool) -> Void) {

        let totalFrames = Int(duration * Double(fps))
        guard totalFrames > 0, let cgImage = image.cgImage else {
            completion(false)
            return
        }

        // Clean up previous file
        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            completion(false)
            return
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        let baseCI = CIImage(cgImage: cgImage)

        DispatchQueue.global(qos: .userInitiated).async {
            for frame in 0..<totalFrames {
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }

                let t = Double(frame) / Double(totalFrames)
                // Cosine ease so velocity is zero at frame 0 and frame N → seamless loop
                let scale = 1.0 + amplitude * (1.0 - cos(2.0 * .pi * t)) / 2.0

                // Scale and center the image
                let tx = size.width * (1.0 - scale) / 2.0
                let ty = size.height * (1.0 - scale) / 2.0
                let transform = CGAffineTransform(translationX: tx, y: ty)
                    .scaledBy(x: scale, y: scale)

                let transformed = baseCI
                    .transformed(by: CGAffineTransform(scaleX: size.width / baseCI.extent.width,
                                                       y: size.height / baseCI.extent.height))
                    .transformed(by: transform)
                    .cropped(to: CGRect(origin: .zero, size: size))

                guard let pool = adaptor.pixelBufferPool else { continue }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let pb = pixelBuffer else { continue }

                ciContext.render(transformed, to: pb)

                let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                adaptor.append(pb, withPresentationTime: pts)
            }

            writerInput.markAsFinished()
            writer.finishWriting {
                completion(writer.status == .completed)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Patcher (caching + hook logic)
// ─────────────────────────────────────────────────────────────────────────────

private final class NowPlayingArtworkPatcher {
    static let shared = NowPlayingArtworkPatcher()

    private let queue = DispatchQueue(label: "npa.patcher", qos: .userInitiated)
    private var previewCache: [String: UIImage] = [:]
    private var videoCache: [String: URL] = [:]
    private var pending: Set<String> = []
    private let cacheDir: URL

    private init() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NPFArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        cacheDir = tmp
        pruneOldFiles()
    }

    /// Stable artwork ID from now-playing info.
    func artworkID(from info: [String: Any]) -> String {
        // Prefer the external content identifier (most reliable)
        if let extID = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, !extID.isEmpty {
            return extID
        }
        // Fallback to artist + album + title hash
        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let album  = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""
        let title  = info[MPMediaItemPropertyTitle] as? String ?? ""
        let combined = "\(artist)|\(album)|\(title)"
        // Simple hash string
        var hash: UInt64 = 5381
        for byte in combined.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return String(hash, radix: 16)
    }

    /// Patch now-playing info with animated artwork.
    func patch(info: inout [String: Any]) {
        // Check system support: the class must have the animated artwork key selector.
        // We use the string key directly — if the system doesn't recognise it, the
        // artwork is silently ignored, which is safe.
        let animatedKey = "MPNowPlayingInfoProperty3x4AnimatedArtwork"

        // Don't replace if already present
        if info[animatedKey] != nil { return }

        // Get the static artwork
        guard let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else { return }
        let coverImage = artwork.image(at: CGSize(width: 1024, height: 1024))
        guard let cover = coverImage else { return }

        let aid = artworkID(from: info)

        // Build 3:4 preview
        let preview: UIImage
        if let cached = queue.sync(execute: { previewCache[aid] }) {
            preview = cached
        } else if let composed = ArtworkComposer.compose(cover: cover, outputSize: NPAConfig.previewSize) {
            queue.sync { previewCache[aid] = composed }
            preview = composed
        } else {
            return
        }

        // Create the animated artwork object
        let animArtwork = createAnimatedArtwork(id: aid, preview: preview, cover: cover)
        info[animatedKey] = animArtwork
    }

    private func createAnimatedArtwork(id: String, preview: UIImage, cover: UIImage) -> NSObject? {
        let cls: AnyClass? = NSClassFromString("MPMediaItemAnimatedArtwork")
        guard let artworkClass = cls else { return nil }

        let sel = NSSelectorFromString("initWithArtworkID:previewImageRequestHandler:videoAssetFileURLRequestHandler:")
        guard let instance = (artworkClass as? NSObject.Type)?.alloc() else { return nil }

        let previewHandler: @convention(block) (CGSize, @escaping (UIImage?) -> Void) -> Void = { [weak self] size, completion in
            if let composed = ArtworkComposer.compose(cover: cover, outputSize: size) {
                completion(composed)
            } else {
                completion(preview)
            }
        }

        let videoHandler: @convention(block) (CGSize, @escaping (URL?) -> Void) -> Void = { [weak self] size, completion in
            guard let self = self else { completion(nil); return }

            // Check video cache
            if let cached = self.queue.sync(execute: { self.videoCache[id] }),
               FileManager.default.fileExists(atPath: cached.path) {
                completion(cached)
                return
            }

            // Check if already rendering
            let alreadyPending = self.queue.sync { () -> Bool in
                if self.pending.contains(id) { return true }
                self.pending.insert(id)
                return false
            }
            if alreadyPending { completion(nil); return }

            // Build the 3:4 portrait for video
            guard let portrait = ArtworkComposer.compose(cover: cover, outputSize: NPAConfig.videoSize) else {
                self.queue.sync { self.pending.remove(id) }
                completion(nil)
                return
            }

            let outputURL = self.cacheDir.appendingPathComponent("\(id).mp4")

            if NPAConfig.animate {
                VideoMaker.render(
                    image: portrait,
                    to: outputURL,
                    size: NPAConfig.videoSize,
                    duration: NPAConfig.loopSeconds,
                    fps: NPAConfig.fps,
                    amplitude: NPAConfig.zoomAmplitude
                ) { success in
                    self.queue.sync {
                        self.pending.remove(id)
                        if success { self.videoCache[id] = outputURL }
                    }
                    completion(success ? outputURL : nil)
                    self.pruneOldFiles()
                }
            } else {
                // Static: render just 2 identical frames (cheapest valid video)
                VideoMaker.render(
                    image: portrait,
                    to: outputURL,
                    size: NPAConfig.videoSize,
                    duration: 0.1,
                    fps: 2,
                    amplitude: 0.0
                ) { success in
                    self.queue.sync {
                        self.pending.remove(id)
                        if success { self.videoCache[id] = outputURL }
                    }
                    completion(success ? outputURL : nil)
                }
            }
        }

        // Invoke the init via NSInvocation-style
        // Since the method takes blocks, use perform selector
        typealias InitMethod = @convention(c) (NSObject, Selector, NSString, Any, Any) -> NSObject?
        let method = class_getInstanceMethod(artworkClass, sel)
        guard let m = method else { return nil }
        let imp = method_getImplementation(m)
        let fn = unsafeBitCast(imp, to: InitMethod.self)
        return fn(instance, sel, id as NSString, previewHandler, videoHandler)
    }

    private func pruneOldFiles() {
        DispatchQueue.global(qos: .utility).async { [cacheDir] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: cacheDir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: .skipsHiddenFiles) else { return }
            let mp4s = files.filter { $0.pathExtension == "mp4" }
            guard mp4s.count > NPAConfig.maxCachedFiles else { return }

            let sorted = mp4s.sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 < d1
            }
            for file in sorted.prefix(mp4s.count - NPAConfig.maxCachedFiles) {
                try? fm.removeItem(at: file)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Hook installation
// ─────────────────────────────────────────────────────────────────────────────

/// Original IMP, kept so we can call through.
private var originalSetNowPlayingInfo: IMP?

/// The replacement block for setNowPlayingInfo:.
/// imp_implementationWithBlock expects (id self, ...) — the selector is implicit.
private let hookBlock: @convention(block) (AnyObject, NSDictionary?) -> Void = { self_, info in
    let sel = NSSelectorFromString("setNowPlayingInfo:")

    guard var dict = info as? [String: Any] else {
        // Call original with nil
        typealias Fn = @convention(c) (AnyObject, Selector, NSDictionary?) -> Void
        let orig = unsafeBitCast(originalSetNowPlayingInfo!, to: Fn.self)
        orig(self_, sel, info)
        return
    }

    NowPlayingArtworkPatcher.shared.patch(info: &dict)

    typealias Fn = @convention(c) (AnyObject, Selector, NSDictionary?) -> Void
    let orig = unsafeBitCast(originalSetNowPlayingInfo!, to: Fn.self)
    orig(self_, sel, dict as NSDictionary)
}

@_cdecl("npa_bootstrap")
public func npa_bootstrap() {
    guard let cls = NSClassFromString("MPNowPlayingInfoCenter") else {
        NSLog("[NPFArt] MPNowPlayingInfoCenter not found")
        return
    }

    let sel = NSSelectorFromString("setNowPlayingInfo:")
    guard let method = class_getInstanceMethod(cls, sel) else {
        NSLog("[NPFArt] setNowPlayingInfo: method not found")
        return
    }

    let newIMP = imp_implementationWithBlock(hookBlock)
    originalSetNowPlayingInfo = method_setImplementation(method, newIMP)
    NSLog("[NPFArt] Hook installed — Plexamp full-screen artwork active")
}
