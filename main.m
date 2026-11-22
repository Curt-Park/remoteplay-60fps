// smooth-anything: captures one window (PS Remote Play by default), interpolates 30 fps -> 60 fps
// with VideoToolbox low-latency frame interpolation, and shows the result in an overlay over the
// captured window or next to it. Apple frameworks only. See README.md for options.

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>

static double HostNow(void) { return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())); }
static CMTime HostTime(double seconds) { return CMTimeMakeWithSeconds(seconds, 1000000000); }
static NSString *FourCC(OSType code) {
    char chars[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
    return [NSString stringWithUTF8String:chars];
}

@interface Smoother : NSObject <SCStreamOutput, SCStreamDelegate>
@property NSString *match;
@property NSInteger targetHeight;
@property NSInteger targetWidth;   // 0 = follow the window's aspect ratio
@property BOOL passthrough;
@property BOOL sideBySide;   // show the result next to the captured window instead of over it
@property double dupThreshold;
@property BOOL debugDiff;
@property NSInteger cushion;   // extra refreshes of delay allowed for absorbing uneven frame arrival
@property BOOL steady;         // keep the extra refresh once it is in use instead of giving it back
@property double minLead;      // seconds before a refresh by which a frame must be committed to make it
@property BOOL upscale;   // super-resolve every shown frame 1.5x after interpolation
@property pid_t targetPid;
@property NSPanel *panel;
@end

@implementation Smoother {
    SCStream *_stream;
    dispatch_queue_t _queue;
    CALayer *_layer;
    NSArray *_onScreen;
    VTFrameProcessor *_processor;
    CVPixelBufferPoolRef _pool;
    VTFrameProcessor *_scaler;
    CVPixelBufferPoolRef _scaledPool;
    CVPixelBufferRef _previousFrame;
    double _previousTime;
    uint8_t *_previousSamples;
    size_t _sampleCount;
    double _sourceInterval;   // smoothed spacing of unique source frames
    NSMutableArray *_pending;   // frames waiting for a display refresh, oldest first
    // stats, reset every report
    double _statsStart;
    int _captured, _unique, _duplicates, _interpolated, _failed;
    // presentation state, guarded by @synchronized(_pending)
    int _shown, _caught, _missed, _phaseCount;
    double _phaseSum;
    double _slotVsync;   // refresh the latest display callback committed for
    double _period;
    BOOL _slotFilled;
    // scheduling state, capture queue only
    double _lastTarget, _behindSum;
    int _spareStreak, _holds, _trims, _behindCount;
    double _interpSum, _interpMax, _captureLagSum, _scaleSum;
    int _scaled;
    CGWindowID _currentWindowID;
    CGRect _currentFrame;
    BOOL _waitingReported;
    int _repeatsInRow;
    double _lastNewMean;
    double _motionLevel;   // smoothed frame-to-frame difference of recent new frames
    BOOL _sceneCut;
    int _cuts;
    id _activationObserver;
}

- (instancetype)init {
    self = [super init];
    _queue = dispatch_queue_create("smooth-anything.frames", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _sourceInterval = 1.0 / 30.0;
    _pending = [NSMutableArray array];
    _period = 1.0 / 60.0;
    return self;
}

- (void)start {
    [self scan];
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) { [self scan]; }];
}

// Remote Play replaces its window when a session starts or goes full screen, so the target is re-resolved periodically.
- (void)scan {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        if (!content) {
            fprintf(stderr, "Cannot list windows: %s\nGrant Screen Recording permission to your terminal in "
                    "System Settings > Privacy & Security, then run again.\n", error.localizedDescription.UTF8String);
            exit(1);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self chooseFrom:content.windows]; });
    }];
}

- (void)chooseFrom:(NSArray<SCWindow *> *)windows {
    SCWindow *best = nil, *current = nil;
    for (SCWindow *window in windows) {
        SCRunningApplication *app = window.owningApplication;
        NSString *haystack = [NSString stringWithFormat:@"%@ %@", app.applicationName, app.bundleIdentifier];
        if ([haystack rangeOfString:self.match options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        if (window.frame.size.width < 200 || window.frame.size.height < 150) continue;
        if (window.windowID == _currentWindowID) current = window;
        CGFloat area = window.frame.size.width * window.frame.size.height;
        CGFloat bestArea = best.frame.size.width * best.frame.size.height;
        if (!best || (window.onScreen && !best.onScreen) || (window.onScreen == best.onScreen && area > bestArea)) best = window;
    }
    if (!best) {
        if (!_waitingReported) fprintf(stderr, "Waiting for a window matching \"%s\"...\n", self.match.UTF8String);
        _waitingReported = YES;
        return;
    }
    _waitingReported = NO;
    // While the app sits in another Space nothing is on screen; stay on the window already captured.
    if (current && !best.onScreen) best = current;
    if (best.windowID == _currentWindowID && CGRectEqualToRect(best.frame, _currentFrame)) return;
    [self stopCapture];
    [self captureWindow:best];
}

- (void)stopCapture {
    SCStream *old = _stream;
    _stream = nil;
    _currentWindowID = 0;
    [old stopCaptureWithCompletionHandler:^(NSError *error) {}];
    dispatch_sync(_queue, ^{
        [self->_processor endSession];
        self->_processor = nil;
        CVPixelBufferPoolRelease(self->_pool);
        self->_pool = NULL;
        [self->_scaler endSession];
        self->_scaler = nil;
        CVPixelBufferPoolRelease(self->_scaledPool);
        self->_scaledPool = NULL;
        CVPixelBufferRelease(self->_previousFrame);
        self->_previousFrame = NULL;
        self->_failed = 0;
    });
}

- (void)captureWindow:(SCWindow *)window {
    CGRect frame = window.frame;
    // Fixed 16:9 because the interpolator rejects some odd sizes; other window shapes get letterboxed.
    NSInteger height = self.targetHeight & ~1;
    NSInteger width = (self.targetWidth > 0 ? self.targetWidth : height * 16 / 9) & ~1;
    self.targetPid = window.owningApplication.processID;
    _currentWindowID = window.windowID;
    _currentFrame = frame;
    fprintf(stderr, "Window: \"%s\" of %s, %.0fx%.0f pt -> processing at %ldx%ld\n", window.title.UTF8String,
            window.owningApplication.applicationName.UTF8String, frame.size.width, frame.size.height, (long)width, (long)height);

    OSType pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (!self.passthrough) {
        __block OSType chosen = 0;
        dispatch_sync(_queue, ^{ chosen = [self startInterpolatorWidth:width height:height]; });
        if (chosen) pixelFormat = chosen;
    }
    if (self.upscale) dispatch_sync(_queue, ^{ [self startScalerWidth:width height:height format:pixelFormat]; });

    [self makeOverlayFor:frame];

    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = width;
    config.height = height;
    config.pixelFormat = pixelFormat;
    config.minimumFrameInterval = CMTimeMake(1, 240);   // a 1/60 floor rejects refreshes that arrive a hair early (about 2 per second)
    config.queueDepth = 6;
    config.showsCursor = NO;
    config.scalesToFit = YES;
    config.colorSpaceName = kCGColorSpaceSRGB;
    config.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    _stream = stream;
    NSError *error = nil;
    if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&error]) {
        fprintf(stderr, "addStreamOutput failed: %s\n", error.localizedDescription.UTF8String);
        exit(1);
    }
    [stream startCaptureWithCompletionHandler:^(NSError *startError) {
        if (!startError) { fprintf(stderr, "Capturing. Ctrl+C in this terminal to quit.\n"); return; }
        fprintf(stderr, "Capture failed to start (%s); retrying.\n", startError.localizedDescription.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{ if (self->_stream == stream) [self stopCapture]; });
    }];
}

- (OSType)startInterpolatorWidth:(NSInteger)width height:(NSInteger)height {
    if (![VTLowLatencyFrameInterpolationConfiguration isSupported]) {
        fprintf(stderr, "Low-latency frame interpolation is not supported on this Mac.\n");
        exit(1);
    }
    if (@available(macOS 27.0, *)) {
        NSInteger maxPixels = [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
        NSInteger maxDimension = [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
        fprintf(stderr, "Interpolator limits: %ld pixels, %ld max dimension (request is %ld pixels)\n",
                (long)maxPixels, (long)maxDimension, (long)(width * height));
    }
    VTLowLatencyFrameInterpolationConfiguration *config =
        [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width frameHeight:height numberOfInterpolatedFrames:1];
    if (!config) {
        fprintf(stderr, "Interpolator rejected %ldx%ld; showing frames without interpolation.\n", (long)width, (long)height);
        return 0;
    }
    NSMutableString *formats = [NSMutableString string];
    OSType chosen = 0;
    NSArray<NSNumber *> *preferred = @[@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                       @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_32BGRA)];
    for (NSNumber *format in config.frameSupportedPixelFormats) [formats appendFormat:@"%@ ", FourCC(format.unsignedIntValue)];
    for (NSNumber *format in preferred) {
        if ([config.frameSupportedPixelFormats containsObject:format]) { chosen = format.unsignedIntValue; break; }
    }
    fprintf(stderr, "Interpolator pixel formats: %s-> using %s\n", formats.UTF8String, FourCC(chosen).UTF8String);
    if (!chosen) { fprintf(stderr, "No pixel format in common with screen capture.\n"); exit(1); }

    VTFrameProcessor *processor = [VTFrameProcessor new];
    NSError *error = nil;
    double begin = HostNow();
    if (![processor startSessionWithConfiguration:config error:&error]) {
        fprintf(stderr, "Interpolator session failed (%s); showing frames without interpolation.\n", error.description.UTF8String);
        return 0;
    }
    _processor = processor;
    fprintf(stderr, "Interpolator ready in %.0f ms\n", (HostNow() - begin) * 1000);

    NSMutableDictionary *attributes = [config.destinationPixelBufferAttributes mutableCopy];
    attributes[(id)kCVPixelBufferWidthKey] = @(width);
    attributes[(id)kCVPixelBufferHeightKey] = @(height);
    attributes[(id)kCVPixelBufferPixelFormatTypeKey] = @(chosen);
    attributes[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_pool);
    return chosen;
}

- (void)startScalerWidth:(NSInteger)width height:(NSInteger)height format:(OSType)format {
    NSArray<NSNumber *> *factors = [VTLowLatencySuperResolutionScalerConfiguration isSupported] ?
        [VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:width frameHeight:height] : @[];
    float factor = [[factors valueForKeyPath:@"@max.self"] floatValue];
    if (factor <= 1) { fprintf(stderr, "Super resolution does not support %ldx%ld; showing frames at capture size.\n", (long)width, (long)height); return; }
    VTLowLatencySuperResolutionScalerConfiguration *config =
        [[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:width frameHeight:height scaleFactor:factor];
    VTFrameProcessor *scaler = [VTFrameProcessor new];
    NSError *error = nil;
    if (![config.frameSupportedPixelFormats containsObject:@(format)] || ![scaler startSessionWithConfiguration:config error:&error]) {
        fprintf(stderr, "Super resolution unavailable (%s); showing frames at capture size.\n", error ? error.description.UTF8String : "pixel format");
        return;
    }
    NSInteger scaledWidth = (NSInteger)lround(width * factor), scaledHeight = (NSInteger)lround(height * factor);
    NSMutableDictionary *attributes = [config.destinationPixelBufferAttributes mutableCopy];
    attributes[(id)kCVPixelBufferWidthKey] = @(scaledWidth);
    attributes[(id)kCVPixelBufferHeightKey] = @(scaledHeight);
    attributes[(id)kCVPixelBufferPixelFormatTypeKey] = @(format);
    attributes[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_scaledPool);
    _scaler = scaler;
    fprintf(stderr, "Super resolution x%.2f -> %ldx%ld\n", factor, (long)scaledWidth, (long)scaledHeight);
}

// Returns a retained buffer: the super-resolved frame, or the input itself when scaling is off or fails.
- (CVPixelBufferRef)upscaled:(CVPixelBufferRef)buffer {
    if (!_scaler) return CVPixelBufferRetain(buffer);
    double begin = HostNow();
    CVPixelBufferRef destination = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _scaledPool, &destination);
    if (!destination) return CVPixelBufferRetain(buffer);
    CVBufferPropagateAttachments(buffer, destination);
    VTFrameProcessorFrame *source = [[VTFrameProcessorFrame alloc] initWithBuffer:buffer presentationTimeStamp:HostTime(begin)];
    VTFrameProcessorFrame *output = [[VTFrameProcessorFrame alloc] initWithBuffer:destination presentationTimeStamp:HostTime(begin)];
    VTLowLatencySuperResolutionScalerParameters *parameters = (source && output) ?
        [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:source destinationFrame:output] : nil;
    NSError *error = nil;
    if (!parameters || ![_scaler processWithParameters:parameters error:&error]) {
        if (_failed++ == 0) fprintf(stderr, "Super resolution failed: %s\n", error ? error.description.UTF8String : "frames rejected");
        CVPixelBufferRelease(destination);
        return CVPixelBufferRetain(buffer);
    }
    _scaleSum += HostNow() - begin;
    _scaled++;
    return destination;
}

- (void)makeOverlayFor:(CGRect)windowFrame {
    // SCWindow frames have a top-left origin on the primary display; Cocoa uses bottom-left.
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    NSRect rect = NSMakeRect(windowFrame.origin.x, primaryHeight - windowFrame.origin.y - windowFrame.size.height,
                             windowFrame.size.width, windowFrame.size.height);
    if (self.sideBySide) rect = [self rectBeside:rect];
    if (self.panel) {
        [self.panel setFrame:rect display:YES];
        [self updateOverlayVisibility];
        return;
    }
    self.panel = [[NSPanel alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:NO];
    self.panel.backgroundColor = NSColor.blackColor;
    self.panel.level = self.sideBySide ? NSFloatingWindowLevel : NSScreenSaverWindowLevel;
    self.panel.ignoresMouseEvents = YES;   // clicks and focus stay with the captured app
    self.panel.hidesOnDeactivate = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.contentView.wantsLayer = YES;

    _layer = [CALayer new];
    _layer.frame = self.panel.contentView.bounds;
    _layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _layer.contentsGravity = kCAGravityResizeAspect;
    _layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    [self.panel.contentView.layer addSublayer:_layer];
    CADisplayLink *link = [self.panel.contentView displayLinkWithTarget:self selector:@selector(refresh:)];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    // The overlay is only up while the captured app is frontmost, so other apps stay usable.
    _activationObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { [self updateOverlayVisibility]; }];
    [self updateOverlayVisibility];
}

// Largest same-shape rectangle that fits in the free space left or right of the window.
- (NSRect)rectBeside:(NSRect)window {
    NSScreen *screen = NSScreen.screens.firstObject;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(NSMakePoint(NSMidX(window), NSMidY(window)), candidate.frame)) screen = candidate;
    }
    NSRect visible = screen.visibleFrame;
    CGFloat rightSpace = NSMaxX(visible) - NSMaxX(window), leftSpace = NSMinX(window) - NSMinX(visible);
    BOOL onRight = rightSpace >= leftSpace;
    CGFloat space = MAX(rightSpace, leftSpace);
    if (space < 200) {
        fprintf(stderr, "No room beside the window; shrink it to at most half the screen width. Using the screen corner.\n");
        space = visible.size.width / 3;
        onRight = YES;
        window.origin.x = NSMaxX(visible) - space - window.size.width;
    }
    CGFloat width = MIN(window.size.width, space), height = width * window.size.height / window.size.width;
    CGFloat x = onRight ? NSMaxX(window) : NSMinX(window) - width;
    return NSMakeRect(x, NSMaxY(window) - height, width, height);
}

- (void)updateOverlayVisibility {
    if (self.sideBySide) { [self.panel orderFrontRegardless]; return; }
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == self.targetPid) [self.panel orderFrontRegardless];
    else [self.panel orderOut:nil];
}

// Remote Play repeats each 30 fps game frame; repeats must not reach the interpolator.
- (BOOL)isDuplicate:(CVPixelBufferRef)buffer {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    BOOL planar = CVPixelBufferIsPlanar(buffer);
    const uint8_t *base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer);
    size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer);
    size_t bytesPerPixel = planar ? 1 : 4, offset = planar ? 0 : 1;
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), step = 8;
    size_t count = (width / step) * (height / step);
    BOOL comparable = _previousSamples && _sampleCount == count;
    if (!comparable) { free(_previousSamples); _previousSamples = malloc(count); _sampleCount = count; }
    uint64_t total = 0;
    int strong = 0;
    size_t index = 0;
    for (size_t y = 0; y < height / step; y++) {
        const uint8_t *row = base + y * step * stride;
        for (size_t x = 0; x < width / step; x++, index++) {
            uint8_t value = row[x * step * bytesPerPixel + offset];
            int difference = comparable ? abs((int)value - (int)_previousSamples[index]) : 0;
            total += (uint64_t)difference;
            if (difference >= 8) strong++;
            _previousSamples[index] = value;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    double mean = (double)total / (double)count;
    // A repeat is either identical or a faint re-encode of the frame before it, whose difference scales with
    // the motion in that frame. An absolute threshold would also swallow real frames in slow scenes.
    BOOL identical = mean < 0.01 && strong == 0;
    // Delivery jitter can hold one source frame for three refreshes, so two faint repeats in a row are allowed;
    // a third faint frame is taken as real motion that slowed down.
    BOOL refinement = _repeatsInRow < 2 && mean < self.dupThreshold * _lastNewMean;
    BOOL duplicate = comparable && (identical || refinement);
    _repeatsInRow = duplicate ? _repeatsInRow + 1 : 0;
    if (!duplicate) _lastNewMean = mean;
    // A cut changes far more of the picture than the motion around it; blending across one smears two scenes together.
    // A false alarm only costs one middle frame, so the bar is low.
    _sceneCut = comparable && !duplicate && mean > 12.0 && mean > 2.5 * _motionLevel;
    if (!duplicate) _motionLevel += 0.2 * (mean - _motionLevel);
    if (self.debugDiff) fprintf(stderr, "diff mean %.3f strong %d %s\n", mean, strong, duplicate ? "repeat" : _sceneCut ? "cut" : "new");
    return duplicate;
}

// Every frame is assigned the display refresh it should appear in and is committed for exactly that refresh.
// Measured on screen, a video layer fed by timestamps or on arrival skipped refreshes and showed well under
// 60 distinct frames per second.
- (void)show:(CVPixelBufferRef)buffer target:(double)target {
    NSArray *item = @[(__bridge id)buffer, @(target)];
    @synchronized (_pending) {
        if (target > _slotVsync + _period / 2) { [_pending addObject:item]; return; }
        // The callback for this frame's refresh already ran; there is still time to commit for it directly.
        BOOL inTime = !_slotFilled && target > _slotVsync - _period / 2 && _slotVsync - HostNow() > self.minLead - 0.001;
        if (!inTime) { _missed++; return; }
        _slotFilled = YES;
        _shown++;
        _caught++;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self present:item]; });
}

- (void)refresh:(CADisplayLink *)link {
    NSArray *next = nil;
    @synchronized (_pending) {
        double target = link.targetTimestamp;
        if (target - link.timestamp > 0.002) _period = target - link.timestamp;
        while (_pending.count && [_pending.firstObject[1] doubleValue] < target - _period / 2) { [_pending removeObjectAtIndex:0]; _missed++; }
        if (_pending.count && [_pending.firstObject[1] doubleValue] < target + _period / 2) {
            next = _pending.firstObject;
            [_pending removeObjectAtIndex:0];
            _shown++;
        }
        _slotFilled = next != nil;
        _slotVsync = target;
    }
    if (next) [self present:next];
}

// Main thread. Setting the surface as layer contents commits it for the coming refresh.
// The array keeps the pixel buffer, and with it the surface, alive while it is on screen.
- (void)present:(NSArray *)item {
    _onScreen = item;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.contents = (__bridge id)CVPixelBufferGetIOSurface((__bridge CVPixelBufferRef)item[0]);
    [CATransaction commit];
    [CATransaction flush];
}

// Returns the frames at the given phases between the two inputs, oldest first, or nil on failure.
- (NSArray *)interpolateFrom:(CVPixelBufferRef)previous at:(double)previousTime to:(CVPixelBufferRef)current at:(double)currentTime
                      phases:(NSArray<NSNumber *> *)phases with:(VTFrameProcessor *)processor {
    NSMutableArray *buffers = [NSMutableArray array];
    NSMutableArray<VTFrameProcessorFrame *> *outputs = [NSMutableArray array];
    for (NSNumber *phase in phases) {
        CVPixelBufferRef destination = NULL;
        CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &destination);
        if (!destination) return nil;
        CVBufferPropagateAttachments(current, destination);
        [buffers addObject:(__bridge_transfer id)destination];
        double time = previousTime + (currentTime - previousTime) * phase.doubleValue;
        VTFrameProcessorFrame *output = [[VTFrameProcessorFrame alloc] initWithBuffer:destination presentationTimeStamp:HostTime(time)];
        if (!output) return nil;
        [outputs addObject:output];
    }
    VTFrameProcessorFrame *source = [[VTFrameProcessorFrame alloc] initWithBuffer:current presentationTimeStamp:HostTime(currentTime)];
    VTFrameProcessorFrame *reference = [[VTFrameProcessorFrame alloc] initWithBuffer:previous presentationTimeStamp:HostTime(previousTime)];
    VTLowLatencyFrameInterpolationParameters *parameters = (source && reference) ?
        [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:source previousFrame:reference
                                                           interpolationPhase:phases destinationFrames:outputs] : nil;
    NSError *error = nil;
    if (!parameters || ![processor processWithParameters:parameters error:&error]) {
        if (_failed++ == 0) fprintf(stderr, "Interpolation failed: %s\n", error ? error.description.UTF8String : "frames rejected");
        return nil;
    }
    return buffers;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSNumber *status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!frame || status.integerValue != SCFrameStatusComplete) return;

    double captureTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
    double arrival = HostNow();
    @synchronized (_pending) { if (_slotVsync > 0) { _phaseSum += fmod(arrival - _slotVsync + 10.0, 1.0 / 60.0); _phaseCount++; } }
    if (_statsStart == 0) _statsStart = arrival;
    _captured++;
    _captureLagSum += arrival - captureTime;

    if ([self isDuplicate:frame]) {
        _duplicates++;
    } else {
        _unique++;
        double gap = _previousFrame ? captureTime - _previousTime : 0;
        if (gap > 0.025 && gap < 0.045) _sourceInterval += 0.1 * (gap - _sourceInterval);
        if (_sceneCut) _cuts++;
        double period, grid;
        @synchronized (_pending) { period = _period; grid = _slotVsync; }
        double (^refreshAtOrAfter)(double) = ^(double time) { return grid + ceil((time - grid) / period - 1e-6) * period; };
        // The source window shows this frame at the first refresh after its capture timestamp.
        double sourceRefresh = refreshAtOrAfter(captureTime);

        CVPixelBufferRef middleOut = NULL;
        if (_processor && _previousFrame && gap < 0.100 && !_sceneCut) {
            double begin = HostNow();
            NSArray *middles = [self interpolateFrom:_previousFrame at:_previousTime to:frame at:captureTime phases:@[@0.5f] with:_processor];
            double elapsed = HostNow() - begin;
            _interpSum += elapsed;
            _interpMax = MAX(_interpMax, elapsed);
            if (middles) { _interpolated++; middleOut = [self upscaled:(__bridge CVPixelBufferRef)middles[0]]; }
        }

        // Source frames are evenly spaced in game time even when delivery jitter lands them one or three refreshes
        // apart, so the middle frame normally takes the refresh right after the previous real frame. It cannot go
        // out earlier than a commit can still make, and may trail the source by at most `cushion` extra refreshes;
        // beyond that the middle frame is skipped to catch up. (Filling long gaps with frames at 1/3 and 2/3 was
        // tried: that interpolator mode takes about 35 ms here and stalls more than it saves.)
        double afterPrevious = _lastTarget + period;
        double first = MAX(afterPrevious, refreshAtOrAfter(HostNow() + self.minLead));
        if (middleOut) {
            BOOL behind = first > sourceRefresh + (1 + self.cushion) * period + period / 2;
            // A spare refresh of delay that has gone unused for 3 s is given back.
            BOOL spare = first > refreshAtOrAfter(HostNow() + self.minLead + 0.003) + period / 2;
            _spareStreak = spare ? _spareStreak + 1 : 0;
            BOOL giveBack = !self.steady && _spareStreak >= 90;
            if (behind || giveBack) {
                CVPixelBufferRelease(middleOut);
                middleOut = NULL;
                _trims++;
                _spareStreak = 0;
            }
        }
        if (_lastTarget > 0 && gap < 0.100 && first > afterPrevious + period / 2) _holds += (int)llround((first - afterPrevious) / period);
        if (middleOut) {
            [self show:middleOut target:first];
            CVPixelBufferRelease(middleOut);
            first += period;
        }
        if (_scaler) {
            // The compositor snapshots the screen at the same point of every refresh, and a captured frame's
            // timestamp is one of those points. GPU work running across the next one made the compositor miss
            // refreshes (measured on screen), so the second upscale waits until that point has passed.
            double sinceComposite = fmod(HostNow() - captureTime, period);
            double untilComposite = period - sinceComposite;
            if (untilComposite < 0.008) usleep((useconds_t)((untilComposite + 0.002) * 1e6));
        }
        CVPixelBufferRef frameOut = [self upscaled:frame];   // off the critical path: the middle frame is already on its way
        first = MAX(first, refreshAtOrAfter(HostNow() + self.minLead));
        [self show:frameOut target:first];
        CVPixelBufferRelease(frameOut);
        _lastTarget = first;
        _behindSum += first - sourceRefresh;
        _behindCount++;
        CVPixelBufferRelease(_previousFrame);
        _previousFrame = CVPixelBufferRetain(frame);
        _previousTime = captureTime;
    }

    double elapsed = arrival - _statsStart;
    if (elapsed >= 2.0) {
        int shown, caught, missed;
        double phase;
        @synchronized (_pending) {
            shown = _shown; caught = _caught; missed = _missed; phase = _phaseCount ? _phaseSum / _phaseCount : 0;
            _shown = _caught = _missed = 0; _phaseSum = 0; _phaseCount = 0;
        }
        fprintf(stderr, "in %.1f fps (unique %.1f, repeats %.1f) | out %.1f fps, held refreshes %d, cuts %d | interp avg %.1f ms max %.1f ms | "
                "upscale avg %.1f ms | behind source window %.1f ms\n",
                _captured / elapsed, _unique / elapsed, _duplicates / elapsed, shown / elapsed, _holds, _cuts,
                _interpolated ? _interpSum / _interpolated * 1000 : 0, _interpMax * 1000,
                _scaled ? _scaleSum / _scaled * 1000 : 0,
                _behindCount ? _behindSum / _behindCount * 1000 : 0);
        if (self.debugDiff || getenv("SMOOTH_DEBUG")) fprintf(stderr, "sched: late commits %d, skipped middles %d, missed %d, frame arrives %.1f ms after refresh\n",
                caught, _trims, missed, phase * 1000);
        _holds = _trims = _behindCount = 0;
        _behindSum = 0;
        _statsStart = arrival;
        _captured = _unique = _duplicates = _interpolated = _cuts = 0;
        _interpSum = _interpMax = _captureLagSum = _scaleSum = 0;
        _scaled = 0;
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(stderr, "Capture stopped (%s); looking for the window again.\n", error.localizedDescription.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{ if (self->_stream == stream) [self stopCapture]; });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Smoother *smoother = [Smoother new];
        smoother.match = @"com.playstation.RemotePlay";
        smoother.targetHeight = 720;
        smoother.dupThreshold = 0.3;
        smoother.minLead = 0.013;   // measured: commits 12.5 ms ahead always made their refresh, 11 ms ahead often did not
        smoother.cushion = 1;
        double seconds = 0;
        for (int i = 1; i < argc; i++) {
            NSString *flag = @(argv[i]);
            NSString *value = i + 1 < argc ? @(argv[i + 1]) : nil;
            if ([flag isEqual:@"--passthrough"]) smoother.passthrough = YES;
            else if ([flag isEqual:@"--side"]) smoother.sideBySide = YES;
            else if ([flag isEqual:@"--debug-diff"]) smoother.debugDiff = YES;
            else if ([flag isEqual:@"--upscale"]) smoother.upscale = YES;
            else if ([flag isEqual:@"--match"] && value) { smoother.match = value; i++; }
            else if ([flag isEqual:@"--height"] && value) { smoother.targetHeight = value.integerValue; i++; }
            else if ([flag isEqual:@"--width"] && value) { smoother.targetWidth = value.integerValue; i++; }
            else if ([flag isEqual:@"--steady"]) smoother.steady = YES;
            else if ([flag isEqual:@"--cushion"] && value) { smoother.cushion = value.integerValue; i++; }
            else if ([flag isEqual:@"--min-lead-ms"] && value) { smoother.minLead = value.doubleValue / 1000; i++; }
            else if ([flag isEqual:@"--dup-thresh"] && value) { smoother.dupThreshold = value.doubleValue; i++; }
            else if ([flag isEqual:@"--seconds"] && value) { seconds = value.doubleValue; i++; }
            else { fprintf(stderr, "Unknown or incomplete option: %s\n", argv[i]); return 2; }
        }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
        [smoother start];
        if (seconds > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        }
        [app run];
    }
    return 0;
}
