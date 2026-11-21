// NowPlayingFullArt — Plexamp edition
//
// Full-screen Lock Screen artwork for Plexamp, using the iOS 26 API:
//
//   MPNowPlayingInfoProperty3x4AnimatedArtwork  (3:4 portrait == full screen)
//   MPMediaItemAnimatedArtwork(artworkID:previewImageRequestHandler:
//                              videoAssetFileURLRequestHandler:)
//
// The player is never modified. We only read the nowPlayingInfo dictionary it
// hands to MediaRemote, and if it has no animated artwork we add our own: a 3:4
// image composed from the existing cover (blurred fill + centred square art)
// plus a short, seamlessly looping zoom rendered to a local mp4.
//
// Based on chdc0/NPFArt.

import Foundation
import UIKit
import MediaPlayer
import AVFoundation
import CoreImage
import ObjectiveC

// MARK: - Configuration

enum NPAConfig {
    /// Only fill in when the player supplied no animated artwork.
    static let animate        = true
    static let previewSize    = CGSize(width: 900, height: 1200)
    static let videoSize      = CGSize(width: 720, height: 960)
    static let loopSeconds    = 3.0
    static let fps: Int32     = 30
    static let zoomAmplitude: CGFloat = 0.05
    static let maxCachedVideos  = 60
    static let maxCachedPreviews = 24
}

// MARK: - 3:4 artwork composition

enum ArtworkComposer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func compose(_ cover: UIImage, size: CGSize) -> UIImage? {
        guard let cg = cover.cgImage else { return nil }

        let rect = CGRect(origin: .zero, size: size)
        let source = CIImage(cgImage: cg)

        let scale = max(size.width / source.extent.width, size.height / source.extent.height)
        var background = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        background = background.transformed(
            by: CGAffineTransform(
                translationX: (size.width - background.extent.width) / 2.0,
                y: (size.height - background.extent.height) / 2.0
            )
        )

        let radius = max(size.width, size.height) * 0.05
        let treated = background
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: rect)
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputBrightnessKey: -0.08,
                    kCIInputSaturationKey: 1.10,
                ]
            )

        guard let backgroundCG = ciContext.createCGImage(treated, from: rect) else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: backgroundCG).draw(in: rect)
            let side = size.width * 0.92
            let frame = CGRect(
                x: (size.width - side) / 2.0,
                y: (size.height - side) / 2.0,
                width: side,
                height: side
            )
            cover.draw(in: frame)
        }
    }
}

// MARK: - Local video rendering

enum VideoMaker {
    static func make(
        image: UIImage,
        size: CGSize,
        url: URL
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let ok = renderSync(image: image, size: size, url: url)
                continuation.resume(returning: ok)
            }
        }
    }

    private static func renderSync(image: UIImage, size: CGSize, url: URL) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: NPAConfig.animate ? 2_000_000 : 400_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 1,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )

        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let frames = NPAConfig.animate ? max(2, Int(NPAConfig.loopSeconds * Double(NPAConfig.fps))) : 2
        var failed = false

        for index in 0 ..< frames {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing || waited > 2000 {
                    failed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
            }
            if failed { break }

            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            }
            if buffer == nil {
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                    kCVPixelFormatType_32BGRA, nil, &buffer)
            }
            guard let pixelBuffer = buffer else { failed = true; break }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let progress = NPAConfig.animate ? CGFloat(index) / CGFloat(frames) : 0
            let amplitude = NPAConfig.animate ? NPAConfig.zoomAmplitude : 0
            let drawn = drawFrame(cgImage, into: pixelBuffer, size: size,
                                  progress: progress, amplitude: amplitude)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            if !drawn || !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: NPAConfig.fps)) {
                failed = true
                break
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if failed || writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private static func drawFrame(
        _ image: CGImage, into pixelBuffer: CVPixelBuffer,
        size: CGSize, progress: CGFloat, amplitude: CGFloat
    ) -> Bool {
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }

        let zoom = 1.0 + Double(amplitude) * (0.5 - 0.5 * cos(2.0 * .pi * Double(progress)))
        let width = size.width * CGFloat(zoom)
        let height = size.height * CGFloat(zoom)

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (size.width - width) / 2.0,
            y: (size.height - height) / 2.0,
            width: width, height: height
        ))
        return true
    }
}

// MARK: - Patcher

typealias NPASetNowPlayingInfoIMP = @convention(c) (AnyObject, Selector, NSDictionary?) -> Void

final class NowPlayingArtworkPatcher {
    static let shared = NowPlayingArtworkPatcher()

    var original: NPASetNowPlayingInfoIMP?

    private let lock = NSLock()
    private var previews: [String: UIImage] = [:]
    private var rendering: Set<String> = []

    private lazy var cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("NowPlayingFullArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    // MARK: Entry point

    func patched(_ info: NSDictionary?) -> NSDictionary? {
        guard #available(iOS 26.0, *) else { return info }
        guard let info = info as? [String: Any] else { return info }

        // Don't replace if already present
        if info[MPNowPlayingInfoProperty3x4AnimatedArtwork] != nil { return info as NSDictionary }

        // Check system supports animated artwork keys
        let supportedKeys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        let has3x4 = supportedKeys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork)
        let has1x1 = supportedKeys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork)
        guard has3x4 || has1x1 else { return info as NSDictionary }

        // Get the static artwork
        guard let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
            return info as NSDictionary
        }

        let identifier = artworkIdentifier(for: info)

        guard let preview = previewImage(for: identifier, artwork: artwork) else {
            return info as NSDictionary
        }

        // Create the animated artwork using the real Swift API
        let animated3x4 = MPMediaItemAnimatedArtwork(
            artworkID: identifier,
            previewImageRequestHandler: { _ in preview },
            videoAssetFileURLRequestHandler: { [weak self] _ in
                guard let self = self else { return nil }
                return await self.videoURL(for: identifier, preview: preview)
            }
        )

        // Square 1:1 variant (same video, iOS crops to fit)
        let animated1x1 = MPMediaItemAnimatedArtwork(
            artworkID: identifier + "_1x1",
            previewImageRequestHandler: { _ in preview },
            videoAssetFileURLRequestHandler: { [weak self] _ in
                guard let self = self else { return nil }
                return await self.videoURL(for: identifier, preview: preview)
            }
        )

        var patched = info
        if has3x4 { patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = animated3x4 }
        if has1x1 { patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = animated1x1 }
        NSLog("[NPFArt] Patched nowPlayingInfo with animated artwork (3x4:%d 1x1:%d)", has3x4 ? 1 : 0, has1x1 ? 1 : 0)
        return patched as NSDictionary
    }

    // MARK: Preview images

    private func previewImage(for identifier: String, artwork: MPMediaItemArtwork) -> UIImage? {
        lock.lock()
        if let cached = previews[identifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let cover = artwork.image(at: CGSize(width: 1200, height: 1200)) else { return nil }
        guard let composed = ArtworkComposer.compose(cover, size: NPAConfig.previewSize) else { return nil }

        lock.lock()
        if previews.count >= NPAConfig.maxCachedPreviews { previews.removeAll() }
        previews[identifier] = composed
        lock.unlock()

        return composed
    }

    // MARK: Video files

    private func videoURL(for identifier: String, preview: UIImage) async -> URL? {
        let url = videoFileURL(for: identifier)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let isOwner = beginRendering(identifier)

        if !isOwner {
            for _ in 0 ..< 300 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }

        defer { endRendering(identifier) }

        let ok = await VideoMaker.make(image: preview, size: NPAConfig.videoSize, url: url)

        if ok {
            pruneCache()
            return url
        }
        return nil
    }

    private func videoFileURL(for identifier: String) -> URL {
        cacheDirectory.appendingPathComponent(identifier + ".mp4")
    }

    private func beginRendering(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if rendering.contains(identifier) { return false }
        rendering.insert(identifier)
        return true
    }

    private func endRendering(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        rendering.remove(identifier)
    }

    private func pruneCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        guard files.count > NPAConfig.maxCachedVideos else { return }

        let sorted = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }

        for stale in sorted.dropFirst(NPAConfig.maxCachedVideos) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: Identity

    private func artworkIdentifier(for info: [String: Any]) -> String {
        if let external = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
           !external.isEmpty {
            return safeName(external)
        }

        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let album = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""
        let title = info[MPMediaItemPropertyTitle] as? String ?? ""
        let combined = "\(artist)|\(album)|\(title)"
        if !combined.replacingOccurrences(of: "|", with: "").isEmpty {
            return safeName(combined)
        }

        return "npa-unknown-\(Int(Date().timeIntervalSince1970))"
    }

    private func safeName(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("_")
            }
            if out.count >= 96 { break }
        }
        return out.isEmpty ? "npa-unknown" : out
    }
}

// MARK: - Hook installation

private let npaHook: NPASetNowPlayingInfoIMP = { object, selector, info in
    let patcher = NowPlayingArtworkPatcher.shared
    let patched = patcher.patched(info)
    patcher.original?(object, selector, patched)
}

@_cdecl("npa_bootstrap")
public func npaBootstrap() {
    guard #available(iOS 26.0, *) else {
        NSLog("[NPFArt] iOS 26+ required")
        return
    }

    if NowPlayingArtworkPatcher.shared.original != nil { return }

    let target: AnyClass = MPNowPlayingInfoCenter.self
    let selector = NSSelectorFromString("setNowPlayingInfo:")

    guard let method = class_getInstanceMethod(target, selector) else {
        NSLog("[NPFArt] setNowPlayingInfo: method not found")
        return
    }

    let originalIMP = method_getImplementation(method)
    NowPlayingArtworkPatcher.shared.original = unsafeBitCast(originalIMP, to: NPASetNowPlayingInfoIMP.self)

    method_setImplementation(method, unsafeBitCast(npaHook, to: IMP.self))
    NSLog("[NPFArt] Hook installed — Plexamp full-screen artwork active")
}
