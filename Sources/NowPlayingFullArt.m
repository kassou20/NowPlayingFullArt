// NowPlayingFullArt.m — Plexamp edition (pure Objective-C)
//
// Full-screen Lock Screen artwork for Plexamp on iOS 26+.
// Rewritten in ObjC to match the proven pattern from Spotify's
// spotifyglass.dylib, which uses completion-handler blocks for
// MPMediaItemAnimatedArtwork instead of Swift async closures.
//
// Sets both MPNowPlayingInfoProperty3x4AnimatedArtwork and
// MPNowPlayingInfoProperty1x1AnimatedArtwork, matching spotifyglass.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ---------------------------------------------------------------------------
#pragma mark - Configuration
// ---------------------------------------------------------------------------

static const CGFloat kPreviewWidth   = 900.0;
static const CGFloat kPreviewHeight  = 1200.0;
static const CGFloat kVideoWidth     = 720.0;
static const CGFloat kVideoHeight    = 960.0;
static const double  kLoopSeconds    = 3.0;
static const int32_t kFPS            = 30;
static const CGFloat kZoomAmplitude  = 0.05;
static const CGFloat kBlurRadius     = 60.0;
static const NSInteger kMaxCachedVideos   = 60;
static const NSInteger kMaxCachedPreviews = 24;

// ---------------------------------------------------------------------------
#pragma mark - Globals
// ---------------------------------------------------------------------------

typedef void (*OrigSetNowPlayingInfoIMP)(id, SEL, NSDictionary *);

static OrigSetNowPlayingInfoIMP sOriginalIMP = NULL;
static NSLock *sLock = nil;
static NSMutableDictionary<NSString *, UIImage *> *sPreviewCache = nil;
static NSMutableSet<NSString *> *sRenderingSet = nil;
static NSString *sCacheDirectory = nil;
static CIContext *sCIContext = nil;
static NSString *sDebugPath = nil;

// Runtime-resolved property key strings (iOS 26+)
static NSString *sKey3x4 = nil;
static NSString *sKey1x1 = nil;

// ---------------------------------------------------------------------------
#pragma mark - Debug Logging
// ---------------------------------------------------------------------------

static void NPFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void NPFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[NPFArt] %@", msg);

    // Also append to breadcrumb file
    if (sDebugPath) {
        NSString *line = [NSString stringWithFormat:@"%@ [NPFArt] %@\n",
                          [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:sDebugPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:sDebugPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
        }
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Cache Directory
// ---------------------------------------------------------------------------

static NSString *cacheDirectory(void) {
    if (sCacheDirectory) return sCacheDirectory;

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"NowPlayingFullArt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    sCacheDirectory = dir;
    return dir;
}

// ---------------------------------------------------------------------------
#pragma mark - Artwork Identifier
// ---------------------------------------------------------------------------

static NSString *safeName(NSString *raw) {
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < raw.length && out.length < 96; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [out appendFormat:@"%C", c];
        } else {
            [out appendString:@"_"];
        }
    }
    return out.length > 0 ? [out copy] : @"npa-unknown";
}

static NSString *artworkIdentifier(NSDictionary *info) {
    NSString *external = info[MPNowPlayingInfoPropertyExternalContentIdentifier];
    if ([external isKindOfClass:[NSString class]] && external.length > 0) {
        return safeName(external);
    }

    NSString *artist = info[MPMediaItemPropertyArtist] ?: @"";
    NSString *album  = info[MPMediaItemPropertyAlbumTitle] ?: @"";
    NSString *title  = info[MPMediaItemPropertyTitle] ?: @"";
    NSString *combined = [NSString stringWithFormat:@"%@|%@|%@", artist, album, title];
    NSString *stripped = [combined stringByReplacingOccurrencesOfString:@"|" withString:@""];
    if (stripped.length > 0) {
        return safeName(combined);
    }

    return [NSString stringWithFormat:@"npa-unknown-%ld",
            (long)[[NSDate date] timeIntervalSince1970]];
}

// ---------------------------------------------------------------------------
#pragma mark - Preview Image Composition (3:4 portrait)
// ---------------------------------------------------------------------------

static UIImage *createPreviewImage(UIImage *cover, CGSize size) {
    CGImageRef cgCover = cover.CGImage;
    if (!cgCover) return nil;

    CGRect rect = CGRectMake(0, 0, size.width, size.height);
    CIImage *source = [CIImage imageWithCGImage:cgCover];

    // Scale to fill
    CGFloat scaleX = size.width / source.extent.size.width;
    CGFloat scaleY = size.height / source.extent.size.height;
    CGFloat scale = MAX(scaleX, scaleY);
    CIImage *scaled = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];

    // Center
    CGFloat tx = (size.width - scaled.extent.size.width) / 2.0;
    CGFloat ty = (size.height - scaled.extent.size.height) / 2.0;
    CIImage *centered = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    // Clamp, blur, crop
    CIImage *clamped = [centered imageByClampingToExtent];
    CIImage *blurred = [clamped imageByApplyingFilter:@"CIGaussianBlur"
                                  withInputParameters:@{kCIInputRadiusKey: @(kBlurRadius)}];
    CIImage *cropped = [blurred imageByCroppingToRect:rect];

    // Darken + saturate
    CIImage *treated = [cropped imageByApplyingFilter:@"CIColorControls"
                                  withInputParameters:@{
        kCIInputBrightnessKey: @(-0.08),
        kCIInputSaturationKey: @(1.10)
    }];

    if (!sCIContext) {
        sCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    }

    CGImageRef backgroundCG = [sCIContext createCGImage:treated fromRect:rect];
    if (!backgroundCG) return nil;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                                          initWithSize:size format:format];

    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx __unused) {
        [[UIImage imageWithCGImage:backgroundCG] drawInRect:rect];

        CGFloat side = size.width * 0.92;
        CGRect frame = CGRectMake(
            (size.width - side) / 2.0,
            (size.height - side) / 2.0,
            side, side
        );
        [cover drawInRect:frame];
    }];

    CGImageRelease(backgroundCG);
    return result;
}

// ---------------------------------------------------------------------------
#pragma mark - Video Frame Drawing
// ---------------------------------------------------------------------------

static BOOL drawFrame(CGImageRef image, CVPixelBufferRef pixelBuffer,
                      CGSize size, CGFloat progress, CGFloat amplitude) {
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        baseAddress,
        (size_t)size.width,
        (size_t)size.height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NO;
    }

    double zoom = 1.0 + (double)amplitude * (0.5 - 0.5 * cos(2.0 * M_PI * (double)progress));
    CGFloat width = size.width * (CGFloat)zoom;
    CGFloat height = size.height * (CGFloat)zoom;

    CGContextTranslateCTM(context, 0, size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(
        (size.width - width) / 2.0,
        (size.height - height) / 2.0,
        width, height
    ), image);

    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Video Rendering (H.264 zoom-loop)
// ---------------------------------------------------------------------------

static BOOL renderVideo(UIImage *image, CGSize size, NSURL *url) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:url error:nil];

    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url
                                                      fileType:AVFileTypeMPEG4
                                                         error:&error];
    if (!writer) {
        NPFLog(@"AVAssetWriter creation failed: %@", error);
        return NO;
    }

    NSDictionary *compressionProps = @{
        AVVideoAverageBitRateKey: @(2000000),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: @(1),
    };

    NSDictionary *outputSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @((int)size.width),
        AVVideoHeightKey: @((int)size.height),
        AVVideoCompressionPropertiesKey: compressionProps,
    };

    AVAssetWriterInput *input = [AVAssetWriterInput
        assetWriterInputWithMediaType:AVMediaTypeVideo
                       outputSettings:outputSettings];
    input.expectsMediaDataInRealTime = NO;

    NSDictionary *bufferAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @((int)size.width),
        (NSString *)kCVPixelBufferHeightKey: @((int)size.height),
    };

    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
            sourcePixelBufferAttributes:bufferAttrs];

    if (![writer canAddInput:input]) {
        NPFLog(@"Cannot add input to writer");
        return NO;
    }
    [writer addInput:input];

    if (![writer startWriting]) {
        NPFLog(@"Writer startWriting failed: %@", writer.error);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    int totalFrames = MAX(2, (int)(kLoopSeconds * (double)kFPS));
    BOOL failed = NO;

    for (int i = 0; i < totalFrames; i++) {
        int waited = 0;
        while (!input.readyForMoreMediaData) {
            if (writer.status != AVAssetWriterStatusWriting || waited > 2000) {
                failed = YES;
                break;
            }
            [NSThread sleepForTimeInterval:0.005];
            waited++;
        }
        if (failed) break;

        CVPixelBufferRef pixelBuffer = NULL;
        CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
        if (pool) {
            CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixelBuffer);
        }
        if (!pixelBuffer) {
            CVPixelBufferCreate(NULL, (size_t)size.width, (size_t)size.height,
                                kCVPixelFormatType_32BGRA, NULL, &pixelBuffer);
        }
        if (!pixelBuffer) {
            failed = YES;
            break;
        }

        CGFloat progress = (CGFloat)i / (CGFloat)totalFrames;
        BOOL drawn = drawFrame(cgImage, pixelBuffer, size, progress, kZoomAmplitude);

        if (!drawn) {
            CVPixelBufferRelease(pixelBuffer);
            failed = YES;
            break;
        }

        CMTime pts = CMTimeMake(i, kFPS);
        if (![adaptor appendPixelBuffer:pixelBuffer withPresentationTime:pts]) {
            CVPixelBufferRelease(pixelBuffer);
            failed = YES;
            break;
        }

        CVPixelBufferRelease(pixelBuffer);
    }

    [input markAsFinished];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    if (failed || writer.status != AVAssetWriterStatusCompleted) {
        NPFLog(@"Video render failed, status=%ld error=%@",
               (long)writer.status, writer.error);
        [fm removeItemAtURL:url error:nil];
        return NO;
    }

    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Cache Management
// ---------------------------------------------------------------------------

static void pruneVideoCache(void) {
    NSString *dir = cacheDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!files || (NSInteger)files.count <= kMaxCachedVideos) return;

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *name in files) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *modified = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        [entries addObject:@{@"path": path, @"date": modified}];
    }

    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]]; // newest first
    }];

    for (NSInteger i = kMaxCachedVideos; i < (NSInteger)entries.count; i++) {
        [fm removeItemAtPath:entries[(NSUInteger)i][@"path"] error:nil];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Preview Cache
// ---------------------------------------------------------------------------

static UIImage *cachedPreview(NSString *identifier, MPMediaItemArtwork *artwork) {
    [sLock lock];
    UIImage *cached = sPreviewCache[identifier];
    [sLock unlock];
    if (cached) return cached;

    UIImage *cover = [artwork imageWithSize:CGSizeMake(1200, 1200)];
    if (!cover) {
        NPFLog(@"Could not extract cover image from MPMediaItemArtwork");
        return nil;
    }

    CGSize previewSize = CGSizeMake(kPreviewWidth, kPreviewHeight);
    UIImage *composed = createPreviewImage(cover, previewSize);
    if (!composed) {
        NPFLog(@"Preview composition failed");
        return nil;
    }

    NPFLog(@"Preview image created: %.0fx%.0f", previewSize.width, previewSize.height);

    [sLock lock];
    if ((NSInteger)sPreviewCache.count >= kMaxCachedPreviews) {
        [sPreviewCache removeAllObjects];
    }
    sPreviewCache[identifier] = composed;
    [sLock unlock];

    return composed;
}

// ---------------------------------------------------------------------------
#pragma mark - Video URL (render on demand)
// ---------------------------------------------------------------------------

static NSURL *videoURLForIdentifier(NSString *identifier) {
    NSString *filename = [identifier stringByAppendingPathExtension:@"mp4"];
    NSString *path = [cacheDirectory() stringByAppendingPathComponent:filename];
    return [NSURL fileURLWithPath:path];
}

static NSURL *ensureVideo(NSString *identifier, UIImage *preview) {
    NSURL *url = videoURLForIdentifier(identifier);
    if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        NPFLog(@"Video cache hit: %@", identifier);
        return url;
    }

    // Check if another thread is already rendering this
    [sLock lock];
    if ([sRenderingSet containsObject:identifier]) {
        [sLock unlock];
        NPFLog(@"Another thread rendering %@, waiting...", identifier);
        // Wait up to 30 seconds
        for (int i = 0; i < 300; i++) {
            [NSThread sleepForTimeInterval:0.1];
            if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                return url;
            }
        }
        NPFLog(@"Timed out waiting for %@", identifier);
        return nil;
    }
    [sRenderingSet addObject:identifier];
    [sLock unlock];

    NPFLog(@"Rendering video for: %@", identifier);
    CGSize videoSize = CGSizeMake(kVideoWidth, kVideoHeight);
    BOOL ok = renderVideo(preview, videoSize, url);

    [sLock lock];
    [sRenderingSet removeObject:identifier];
    [sLock unlock];

    if (ok) {
        NPFLog(@"Video rendered: %@", url.lastPathComponent);
        pruneVideoCache();
        return url;
    }
    NPFLog(@"Video render FAILED for: %@", identifier);
    return nil;
}

// ---------------------------------------------------------------------------
#pragma mark - Patching nowPlayingInfo
// ---------------------------------------------------------------------------

static NSDictionary *patchedInfo(NSDictionary *info) {
    if (!info) return info;

    // We need the runtime keys; if they were not resolved, bail
    if (!sKey3x4 && !sKey1x1) {
        NPFLog(@"No animated artwork keys resolved, skipping");
        return info;
    }

    // Don't replace if 3x4 is already set
    if (sKey3x4 && info[sKey3x4] != nil) {
        return info;
    }

    // Check supportedAnimatedArtworkKeys
    BOOL has3x4 = NO;
    BOOL has1x1 = NO;

    SEL supportedSel = NSSelectorFromString(@"supportedAnimatedArtworkKeys");
    if ([MPNowPlayingInfoCenter respondsToSelector:supportedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *supported = [MPNowPlayingInfoCenter performSelector:supportedSel];
#pragma clang diagnostic pop
        NPFLog(@"supportedAnimatedArtworkKeys: %@", supported);

        if (sKey3x4) has3x4 = [supported containsObject:sKey3x4];
        if (sKey1x1) has1x1 = [supported containsObject:sKey1x1];
    } else {
        NPFLog(@"supportedAnimatedArtworkKeys not available, trying both keys");
        has3x4 = (sKey3x4 != nil);
        has1x1 = (sKey1x1 != nil);
    }

    if (!has3x4 && !has1x1) {
        NPFLog(@"No animated artwork keys supported by system");
        return info;
    }

    // Get the static artwork
    MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
    if (![artwork isKindOfClass:[MPMediaItemArtwork class]]) {
        NPFLog(@"No MPMediaItemArtwork in nowPlayingInfo");
        return info;
    }

    NSString *artist = info[MPMediaItemPropertyArtist] ?: @"(unknown)";
    NSString *title  = info[MPMediaItemPropertyTitle] ?: @"(unknown)";
    NPFLog(@"Patching info for: %@ - %@", artist, title);

    NSString *identifier = artworkIdentifier(info);

    UIImage *preview = cachedPreview(identifier, artwork);
    if (!preview) {
        NPFLog(@"Could not create preview, skipping");
        return info;
    }

    // Create MPMediaItemAnimatedArtwork using runtime
    Class artworkClass = NSClassFromString(@"MPMediaItemAnimatedArtwork");
    if (!artworkClass) {
        NPFLog(@"MPMediaItemAnimatedArtwork class not found");
        return info;
    }

    SEL initSel = NSSelectorFromString(
        @"initWithArtworkID:previewImageRequestHandler:videoAssetFileURLRequestHandler:");

    // Define block types matching the spotifyglass pattern:
    // previewImageRequestHandler: (void (^)(CGSize requestedSize, void (^completion)(UIImage *)))
    // videoAssetFileURLRequestHandler: (void (^)(CGSize requestedSize, void (^completion)(NSURL *)))
    typedef void (^PreviewCompletion)(UIImage *);
    typedef void (^VideoCompletion)(NSURL *);
    typedef void (^PreviewHandler)(CGSize requestedSize, PreviewCompletion completion);
    typedef void (^VideoHandler)(CGSize requestedSize, VideoCompletion completion);

    // Capture identifier and preview for use in blocks
    NSString *capturedId = [identifier copy];
    UIImage *capturedPreview = preview;

    PreviewHandler previewHandler = ^(CGSize requestedSize __unused,
                                      PreviewCompletion completion) {
        NPFLog(@"Preview requested for %@", capturedId);
        completion(capturedPreview);
    };

    VideoHandler videoHandler = ^(CGSize requestedSize __unused,
                                  VideoCompletion completion) {
        NPFLog(@"Video requested for %@", capturedId);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSURL *videoURL = ensureVideo(capturedId, capturedPreview);
            NPFLog(@"Video completion callback, url=%@", videoURL);
            completion(videoURL);
        });
    };

    // Use objc_msgSend to call the init method with the blocks
    // We need to cast objc_msgSend to the correct function pointer type
    id artwork3x4 = nil;
    {
        id allocated = [artworkClass alloc];
        if (!allocated) {
            NPFLog(@"Failed to alloc MPMediaItemAnimatedArtwork");
            return info;
        }

        // Build NSInvocation for the init
        NSMethodSignature *sig = [allocated methodSignatureForSelector:initSel];
        if (!sig) {
            NPFLog(@"initWithArtworkID:... method signature not found");
            return info;
        }

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:allocated];
        [inv setSelector:initSel];

        NSString *artworkID3x4 = capturedId;
        [inv setArgument:&artworkID3x4 atIndex:2];
        [inv setArgument:&previewHandler atIndex:3];
        [inv setArgument:&videoHandler atIndex:4];
        [inv invoke];

        void *returnVal3x4 = NULL;
        [inv getReturnValue:&returnVal3x4];
        artwork3x4 = (__bridge_transfer id)returnVal3x4;
    }

    if (!artwork3x4) {
        NPFLog(@"MPMediaItemAnimatedArtwork init returned nil");
        return info;
    }
    NPFLog(@"MPMediaItemAnimatedArtwork created (3x4)");

    // Create a 1x1 variant
    id artwork1x1 = nil;
    {
        id allocated = [artworkClass alloc];
        if (allocated) {
            NSMethodSignature *sig = [allocated methodSignatureForSelector:initSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:allocated];
                [inv setSelector:initSel];

                NSString *artworkID1x1 = [capturedId stringByAppendingString:@"_1x1"];
                [inv setArgument:&artworkID1x1 atIndex:2];
                [inv setArgument:&previewHandler atIndex:3];
                [inv setArgument:&videoHandler atIndex:4];
                [inv invoke];

                void *returnVal1x1 = NULL;
                [inv getReturnValue:&returnVal1x1];
                artwork1x1 = (__bridge_transfer id)returnVal1x1;
            }
        }
    }

    // Build the patched dictionary
    NSMutableDictionary *patched = [info mutableCopy];
    if (has3x4 && sKey3x4 && artwork3x4) {
        patched[sKey3x4] = artwork3x4;
    }
    if (has1x1 && sKey1x1 && artwork1x1) {
        patched[sKey1x1] = artwork1x1;
    }

    NPFLog(@"Set 3x4: %d, 1x1: %d", has3x4 && artwork3x4 != nil, has1x1 && artwork1x1 != nil);
    return [patched copy];
}

// ---------------------------------------------------------------------------
#pragma mark - Swizzled IMP
// ---------------------------------------------------------------------------

static void hooked_setNowPlayingInfo(id self, SEL _cmd, NSDictionary *info) {
    NSDictionary *patched = patchedInfo(info);
    if (sOriginalIMP) {
        sOriginalIMP(self, _cmd, patched);
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Resolve iOS 26+ Property Keys at Runtime
// ---------------------------------------------------------------------------

static BOOL resolvePropertyKeys(void) {
    void *handle = dlopen(
        "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer",
        RTLD_LAZY | RTLD_NOLOAD);

    if (!handle) {
        // Try loading it fresh
        handle = dlopen(
            "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer",
            RTLD_LAZY);
    }

    if (!handle) {
        NPFLog(@"Failed to dlopen MediaPlayer framework");
        return NO;
    }

    void *sym3x4 = dlsym(handle, "MPNowPlayingInfoProperty3x4AnimatedArtwork");
    if (sym3x4) {
        sKey3x4 = *(__unsafe_unretained NSString **)sym3x4;
        NPFLog(@"Resolved key3x4: %@", sKey3x4);
    } else {
        NPFLog(@"MPNowPlayingInfoProperty3x4AnimatedArtwork not found in framework");
    }

    void *sym1x1 = dlsym(handle, "MPNowPlayingInfoProperty1x1AnimatedArtwork");
    if (sym1x1) {
        sKey1x1 = *(__unsafe_unretained NSString **)sym1x1;
        NPFLog(@"Resolved key1x1: %@", sKey1x1);
    } else {
        NPFLog(@"MPNowPlayingInfoProperty1x1AnimatedArtwork not found in framework");
    }

    // Don't dlclose — we need the symbols to remain valid
    return (sKey3x4 != nil || sKey1x1 != nil);
}

// ---------------------------------------------------------------------------
#pragma mark - Hook Installation
// ---------------------------------------------------------------------------

static void installHook(void) {
    NPFLog(@"Installing hook...");

    // Check iOS version: we need iOS 26+ (which reports as 19.0 internally)
    if (@available(iOS 26.0, *)) {
        NPFLog(@"iOS 26 check: PASS");
    } else {
        NPFLog(@"iOS 26 check: FAIL (iOS 26+ required)");
        return;
    }

    // Resolve property keys from MediaPlayer framework
    if (!resolvePropertyKeys()) {
        NPFLog(@"Could not resolve any animated artwork keys, aborting");
        return;
    }

    // Verify MPMediaItemAnimatedArtwork class exists
    Class artworkClass = NSClassFromString(@"MPMediaItemAnimatedArtwork");
    if (!artworkClass) {
        NPFLog(@"MPMediaItemAnimatedArtwork class not available");
        return;
    }
    NPFLog(@"MPMediaItemAnimatedArtwork class found");

    // Check supportedAnimatedArtworkKeys
    SEL supportedSel = NSSelectorFromString(@"supportedAnimatedArtworkKeys");
    if ([MPNowPlayingInfoCenter respondsToSelector:supportedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *supported = [MPNowPlayingInfoCenter performSelector:supportedSel];
#pragma clang diagnostic pop
        NPFLog(@"supportedAnimatedArtworkKeys: %@", supported);
    } else {
        NPFLog(@"supportedAnimatedArtworkKeys selector not available");
    }

    // Swizzle -[MPNowPlayingInfoCenter setNowPlayingInfo:]
    Class target = [MPNowPlayingInfoCenter class];
    SEL selector = NSSelectorFromString(@"setNowPlayingInfo:");
    Method method = class_getInstanceMethod(target, selector);
    if (!method) {
        NPFLog(@"setNowPlayingInfo: method not found on MPNowPlayingInfoCenter");
        return;
    }

    IMP originalIMP = method_getImplementation(method);
    sOriginalIMP = (OrigSetNowPlayingInfoIMP)originalIMP;

    method_setImplementation(method, (IMP)hooked_setNowPlayingInfo);
    NPFLog(@"Hook installed on setNowPlayingInfo:");
    NPFLog(@"Full-screen animated artwork active");
}

// ---------------------------------------------------------------------------
#pragma mark - Constructor
// ---------------------------------------------------------------------------

__attribute__((constructor))
static void npa_constructor(void) {
    // Initialize globals
    sLock = [[NSLock alloc] init];
    sPreviewCache = [NSMutableDictionary dictionary];
    sRenderingSet = [NSMutableSet set];

    // Set up debug breadcrumb file
    sDebugPath = [NSTemporaryDirectory()
                  stringByAppendingPathComponent:@"NPFArt_debug.txt"];
    // Truncate existing debug file
    [@"" writeToFile:sDebugPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NPFLog(@"Constructor fired");

    // Dispatch hook installation to main queue so UIKit/MediaPlayer are ready
    dispatch_async(dispatch_get_main_queue(), ^{
        NPFLog(@"Main queue callback, installing hook");
        installHook();
    });
}
