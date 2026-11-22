// smooth-anything: captures one window (picked with the mouse, or named with --match), interpolates
// 30 fps -> 60 fps with VideoToolbox low-latency frame interpolation, and shows the result in its own
// window. Apple frameworks only. See README.md for options.

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>

// The interpolator accepts 1280x720 and 1920x1080 only, and 1080p takes about 100 ms on an M1.
static const NSInteger kProcessWidth = 1280, kProcessHeight = 720;
// Seconds before a refresh by which a frame must be committed to make it. Measured: 12.5 ms ahead always
// made the refresh, 11 ms ahead often did not.
static const double kCommitLead = 0.013;
// A capture whose difference is below this fraction of the last real frame's difference is a repeat.
static const double kRepeatRatio = 0.3;

static double HostNow(void) { return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())); }
static CMTime HostTime(double seconds) { return CMTimeMakeWithSeconds(seconds, 1000000000); }
static NSString *FourCC(OSType code) {
    char chars[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
    return [NSString stringWithUTF8String:chars];
}

// Content view of the output window. Double-click, or F / Esc while the window has the keyboard, toggles full screen.
@interface OutputView : NSView
@property (copy) void (^toggleFullScreen)(void);
@property (copy) BOOL (^isFullScreen)(void);
@end

@implementation OutputView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) self.toggleFullScreen(); else [super mouseDown:event];
}
- (void)keyDown:(NSEvent *)event {
    BOOL escape = event.keyCode == 53, letterF = [event.charactersIgnoringModifiers.lowercaseString isEqual:@"f"];
    if (letterF || (escape && self.isFullScreen())) self.toggleFullScreen(); else [super keyDown:event];
}
@end

// A panel that takes the keyboard without activating this app, so the captured app stays frontmost
// and keeps receiving controller input while the output window is used.
@interface OutputPanel : NSPanel
@end

@implementation OutputPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface Smoother : NSObject <SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, NSWindowDelegate>
@property NSString *match;        // nil = ask with the system window picker
@property BOOL passthrough;
@property double sharpness;       // unsharp-mask strength applied to every shown frame; 0 = off
@property BOOL logStalls;         // print gaps of 0.12-3 s in source frames and in shown frames
@property double cropTop;         // points cut from the top of the captured window; negative = automatic
@property BOOL debugDiff;
@property NSInteger cushion;   // extra refreshes of delay allowed for absorbing uneven frame arrival
@property BOOL steady;         // keep the extra refresh once it is in use instead of giving it back
@property BOOL upscale;   // super-resolve every shown frame 1.5x after interpolation
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
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalQueue;
    id<MTLComputePipelineState> _sharpenPipeline;
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferPoolRef _sharpPool;
    size_t _sharpWidth;
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
    BOOL _waitingReported;
    int _repeatsInRow, _restShown;
    NSUInteger _captureGeneration;
    CVPixelBufferRef _restFrame;
    double _restTime;
    double _lastNewMean, _lastRepeatMean, _lastNewTime;
    double _motionLevel;   // smoothed frame-to-frame difference of recent new frames
    BOOL _sceneCut;
    int _cuts;
    CGWindowID _pickedWindowID;
    SCContentFilter *_fixedFilter;   // set when the picked content cannot be found again by app name
    BOOL _everCaptured;
    SCStream *_queueStream;          // capture queue only: the stream whose frames are accepted
    double _lastUniqueArrival, _lastPresent;
    OSType _processorFormat;
    SCContentFilter *_filter;
    SCStreamConfiguration *_config;
    CGRect _sourceFrame;     // captured window, points
    CGRect _litArea;         // everything seen lit in the window so far, points
    NSPanel *_fullPanel;
    CGSize _currentSize;
    BOOL _fullScreen;
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
    [self makeOutputWindow];
    if (self.match) { [self follow]; return; }
    SCContentSharingPickerConfiguration *configuration = [SCContentSharingPickerConfiguration new];
    configuration.allowedPickerModes = SCContentSharingPickerModeSingleWindow;
    configuration.excludedBundleIDs = @[];
    configuration.excludedWindowIDs = @[@(self.panel.windowNumber)];
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    picker.defaultConfiguration = configuration;
    [picker addObserver:self];
    picker.active = YES;
    fprintf(stderr, "Click the window to smooth.\n");
    [NSApp activateIgnoringOtherApps:YES];
    [picker presentPickerUsingContentStyle:SCShareableContentStyleWindow];
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker didUpdateWithFilter:(SCContentFilter *)filter forStream:(SCStream *)stream {
    SCWindow *window = filter.includedWindows.firstObject;
    picker.active = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        SCRunningApplication *app = window.owningApplication;
        NSString *name = app.bundleIdentifier.length ? app.bundleIdentifier : app.applicationName;
        if (!window || !name.length) {
            // Without the window's identity or an app to search for, the picked content is captured as it is,
            // and the same filter is retried if the capture stops.
            self->_fixedFilter = filter;
            [self captureWithFilter:filter frame:filter.contentRect];
            return;
        }
        // The app is remembered as well as the window: when the app replaces its window, its largest one is followed.
        self->_pickedWindowID = window.windowID;
        self.match = name;
        [self follow];
    });
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker didCancelForStream:(SCStream *)stream {
    fprintf(stderr, "No window chosen.\n");
    exit(0);
}

- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
    fprintf(stderr, "Window picker failed: %s\nPass --match <app name> instead.\n", error.localizedDescription.UTF8String);
    exit(1);
}

- (void)follow {
    [self scan];
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) { [self scan]; }];
}

// Remote Play replaces its window when a session starts or goes full screen, so the target is re-resolved periodically.
- (void)scan {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        if (!content && self->_everCaptured) return;   // a passing failure mid-session; the next scan tries again
        if (!content) {
            fprintf(stderr, "Cannot list windows: %s\nGrant Screen Recording permission to your terminal in "
                    "System Settings > Privacy & Security, then run again.\n", error.localizedDescription.UTF8String);
            exit(1);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self chooseFrom:content.windows]; });
    }];
}

- (void)chooseFrom:(NSArray<SCWindow *> *)windows {
    SCWindow *best = nil, *current = nil, *picked = nil;
    for (SCWindow *window in windows) {
        if (window.windowID == self.panel.windowNumber) continue;
        SCRunningApplication *app = window.owningApplication;
        NSString *haystack = [NSString stringWithFormat:@"%@ %@", app.applicationName, app.bundleIdentifier];
        if ([haystack rangeOfString:self.match options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        if (window.frame.size.width < 200 || window.frame.size.height < 150) continue;
        if (window.windowID == _currentWindowID) current = window;
        if (window.windowID == _pickedWindowID) picked = window;
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
    if (picked) best = picked;
    if (best.windowID == _currentWindowID && CGSizeEqualToSize(best.frame.size, _currentSize)) { [self findContent]; return; }
    [self stopCapture];
    [self captureWindow:best];
}

// The interpolator and scaler sessions are kept: they do not depend on the window and take about a second to start.
- (void)stopCapture {
    SCStream *old = _stream;
    _stream = nil;
    _filter = nil;
    _currentWindowID = 0;
    _litArea = CGRectZero;
    [old stopCaptureWithCompletionHandler:^(NSError *error) {}];
    dispatch_sync(_queue, ^{
        self->_queueStream = nil;
        CVPixelBufferRelease(self->_previousFrame);
        self->_previousFrame = NULL;
        CVPixelBufferRelease(self->_restFrame);
        self->_restFrame = NULL;
        self->_captureGeneration++;
        self->_failed = 0;
    });
}

- (void)captureWindow:(SCWindow *)window {
    _currentWindowID = window.windowID;
    _currentSize = window.frame.size;
    fprintf(stderr, "Window: \"%s\" of %s\n", window.title.UTF8String, window.owningApplication.applicationName.UTF8String);
    [self captureWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:window] frame:window.frame];
}

- (void)captureWithFilter:(SCContentFilter *)filter frame:(CGRect)frame {
    // Fixed 16:9 because the interpolator rejects some odd sizes; other window shapes get letterboxed.
    NSInteger width = kProcessWidth, height = kProcessHeight;
    fprintf(stderr, "Source %.0fx%.0f pt -> processing at %ldx%ld\n", frame.size.width, frame.size.height, (long)width, (long)height);

    OSType pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (!self.passthrough) {
        __block OSType chosen = 0;
        dispatch_sync(_queue, ^{ chosen = self->_processor ? self->_processorFormat : [self startInterpolatorWidth:width height:height]; });
        if (chosen) { pixelFormat = chosen; _processorFormat = chosen; }
    }
    if (self.upscale) dispatch_sync(_queue, ^{ if (!self->_scaler) [self startScalerWidth:width height:height format:pixelFormat]; });

    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = width;
    config.height = height;
    config.pixelFormat = pixelFormat;
    config.minimumFrameInterval = CMTimeMake(1, 240);   // a 1/60 floor rejects refreshes that arrive a hair early (about 2 per second)
    config.queueDepth = 8;   // the maximum: with upscaling and sharpening off, shown frames are capture surfaces held here
    config.showsCursor = NO;
    config.scalesToFit = YES;
    CGFloat cropTop = [self cropTopFor:frame];
    if (cropTop > 0) config.sourceRect = CGRectMake(0, cropTop, frame.size.width, frame.size.height - cropTop);
    _config = config;
    _filter = filter;
    _sourceFrame = frame;
    config.colorSpaceName = kCGColorSpaceSRGB;
    config.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;

    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    _stream = stream;
    dispatch_sync(_queue, ^{ self->_queueStream = stream; });
    NSError *error = nil;
    if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&error]) {
        fprintf(stderr, "addStreamOutput failed: %s\n", error.localizedDescription.UTF8String);
        exit(1);
    }
    [stream startCaptureWithCompletionHandler:^(NSError *startError) {
        if (!startError) { self->_everCaptured = YES; fprintf(stderr, "Capturing. Ctrl+C in this terminal to quit.\n"); return; }
        fprintf(stderr, "Capture failed to start (%s); retrying.\n", startError.localizedDescription.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{ [self recoverFrom:stream]; });
    }];
}

// Main thread. A followed app is found again by the next scan; a fixed filter has no scan, so it is restarted here.
- (void)recoverFrom:(SCStream *)stream {
    if (_stream != stream) return;
    [self stopCapture];
    SCContentFilter *filter = _fixedFilter;
    if (!filter) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_stream) [self captureWithFilter:filter frame:filter.contentRect];
    });
}

// A window that does not fill a screen is assumed to have a standard title bar, which is left out.
- (CGFloat)cropTopFor:(CGRect)frame {
    BOOL fillsScreen = NO;
    for (NSScreen *screen in NSScreen.screens) if (CGSizeEqualToSize(screen.frame.size, frame.size)) fillsScreen = YES;
    CGFloat cropTop = self.cropTop >= 0 ? self.cropTop : (fillsScreen ? 0 : 28);
    return cropTop < frame.size.height / 2 ? cropTop : 0;
}

// A video app letterboxes its 16:9 picture inside a window of another shape. Capturing the whole window
// would letterbox it again and leave the output with black borders, so the lit area of the window is
// measured from a screenshot on every scan and only the 16:9 area around it is captured.
// The lit area is accumulated and never shrinks: a dark scene with black edges must not be mistaken for
// borders, which would cut off the sides of the picture for good.
- (void)findContent {
    SCContentFilter *filter = _filter;
    SCStream *stream = _stream;
    if (!filter || !stream || self.cropTop >= 0) return;
    CGRect frame = _sourceFrame;
    CGFloat top = [self cropTopFor:frame];
    SCStreamConfiguration *shot = [SCStreamConfiguration new];
    shot.width = (size_t)frame.size.width;
    shot.height = (size_t)frame.size.height;
    shot.showsCursor = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:shot completionHandler:^(CGImageRef image, NSError *error) {
        if (!image) return;
        CGRect lit = [self litAreaIn:image below:top];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (CGRectIsNull(lit) || self->_stream != stream) return;
            self->_litArea = CGRectIsEmpty(self->_litArea) ? lit : CGRectUnion(self->_litArea, lit);
            CGRect area = self->_litArea;
            // Anything that is not a 16:9 picture (an ordinary window, or too little seen so far) is captured whole.
            CGRect target = CGRectMake(0, top, frame.size.width, frame.size.height - top);
            if (area.size.width >= frame.size.width * 0.4 && fabs(area.size.width / area.size.height - 16.0 / 9.0) <= 0.07) {
                // The smallest 16:9 rectangle containing the lit area: showing a sliver of border beats cutting picture.
                CGFloat widest = MIN(frame.size.width, (frame.size.height - top) * 16.0 / 9.0);
                CGFloat width = MIN(MAX(area.size.width, area.size.height * 16.0 / 9.0), widest), height = width * 9.0 / 16.0;
                CGFloat x = MIN(MAX(CGRectGetMidX(area) - width / 2, 0), frame.size.width - width);
                CGFloat y = MAX(MIN(CGRectGetMidY(area) - height / 2, frame.size.height - height), top);
                target = CGRectMake(x, y, width, height);
            }
            CGRect current = self->_config.sourceRect;
            if (fabs(target.origin.x - current.origin.x) < 1.5 && fabs(target.origin.y - current.origin.y) < 1.5 &&
                fabs(target.size.width - current.size.width) < 1.5 && fabs(target.size.height - current.size.height) < 1.5) return;
            fprintf(stderr, "Capturing %.0fx%.0f at (%.0f, %.0f) of the %.0fx%.0f window\n", target.size.width, target.size.height,
                    target.origin.x, target.origin.y, frame.size.width, frame.size.height);
            self->_config.sourceRect = target;
            [stream updateConfiguration:self->_config completionHandler:^(NSError *updateError) {
                if (updateError) fprintf(stderr, "Could not change the captured area: %s\n", updateError.localizedDescription.UTF8String);
            }];
        });
    }];
}

// Returns the bounding box of everything that is not black, in image coordinates (top-left origin).
- (CGRect)litAreaIn:(CGImageRef)image below:(CGFloat)top {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (width < 64 || height < 64) return CGRectNull;
    uint8_t *gray = calloc(width * height, 1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(gray, width, height, 8, width, space, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    BOOL (^rowLit)(size_t, size_t, size_t) = ^BOOL(size_t y, size_t fromX, size_t toX) {
        size_t lit = 0, samples = 0;
        for (size_t x = fromX; x < toX; x += 3, samples++) if (gray[y * width + x] > 24) lit++;
        return lit * 33 >= samples;   // at least 3 % of the row
    };
    BOOL (^columnLit)(size_t, size_t, size_t) = ^BOOL(size_t x, size_t fromY, size_t toY) {
        size_t lit = 0, samples = 0;
        for (size_t y = fromY; y < toY; y += 3, samples++) if (gray[y * width + x] > 24) lit++;
        return lit * 33 >= samples;
    };
    size_t y0 = (size_t)top, y1 = height;
    while (y0 < y1 && !rowLit(y0, 0, width)) y0++;
    while (y1 > y0 && !rowLit(y1 - 1, 0, width)) y1--;
    size_t x0 = 0, x1 = width;
    while (x0 < x1 && !columnLit(x0, y0, y1)) x0++;
    while (x1 > x0 && !columnLit(x1 - 1, y0, y1)) x1--;
    free(gray);
    if (x1 <= x0 + 32 || y1 <= y0 + 32) return CGRectNull;
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
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
// Returns a retained frame ready for display: super-resolved when upscaling is on, then sharpened.
- (CVPixelBufferRef)upscaled:(CVPixelBufferRef)buffer {
    double begin = HostNow();
    CVPixelBufferRef result = [self superResolved:buffer];
    if (self.sharpness > 0) {
        CVPixelBufferRef sharper = [self sharpened:result];
        if (sharper) { CVPixelBufferRelease(result); result = sharper; }
    }
    if (result != buffer) { _scaleSum += HostNow() - begin; _scaled++; }
    return result;
}

// Returns a retained buffer: the super-resolved frame, or the input itself when scaling is off or fails.
- (CVPixelBufferRef)superResolved:(CVPixelBufferRef)buffer {
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
    return destination;
}

// Unsharp mask on the luma plane: each pixel is pushed away from a small blur of its surroundings. The video
// stream carries little detail beyond 720p, so no upscaler recovers more; raising edge contrast is what makes
// the picture read as sharper. The push is capped so strong edges do not grow halos.
// Returns a retained buffer, or NULL when sharpening is unavailable.
- (CVPixelBufferRef)sharpened:(CVPixelBufferRef)source {
    static NSString *const shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void sharpen(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
        "                    constant float &amount [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {\n"
        "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
        "    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);\n"
        "    float2 size = float2(src.get_width(), src.get_height());\n"
        "    float2 uv = (float2(gid) + 0.5) / size, o = 1.25 / size;\n"
        "    float c = src.sample(s, uv).r;\n"
        "    float blur = 0.25 * (src.sample(s, uv + o).r + src.sample(s, uv - o).r +\n"
        "                         src.sample(s, uv + float2(o.x, -o.y)).r + src.sample(s, uv + float2(-o.x, o.y)).r);\n"
        "    dst.write(float4(saturate(c + clamp((c - blur) * amount, -0.10, 0.10)), 0, 0, 1), gid);\n"
        "}\n";
    size_t width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source);
    if (!_metalDevice) {
        _metalDevice = MTLCreateSystemDefaultDevice();
        _metalQueue = [_metalDevice newCommandQueue];
        NSError *error = nil;
        id<MTLLibrary> library = [_metalDevice newLibraryWithSource:shader options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"sharpen"];
        _sharpenPipeline = function ? [_metalDevice newComputePipelineStateWithFunction:function error:&error] : nil;
        CVMetalTextureCacheCreate(NULL, NULL, _metalDevice, NULL, &_textureCache);
        if (!_sharpenPipeline) fprintf(stderr, "Sharpening is unavailable: %s\n", error.localizedDescription.UTF8String);
    }
    if (!_sharpenPipeline || !CVPixelBufferIsPlanar(source)) return NULL;
    if (!_sharpPool || _sharpWidth != width) {
        CVPixelBufferPoolRelease(_sharpPool);
        NSDictionary *attributes = @{(id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height),
                                     (id)kCVPixelBufferPixelFormatTypeKey: @(CVPixelBufferGetPixelFormatType(source)),
                                     (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_sharpPool);
        _sharpWidth = width;
    }
    CVPixelBufferRef output = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _sharpPool, &output);
    if (!output) return NULL;
    CVMetalTextureRef lumaIn = NULL, lumaOut = NULL, chromaIn = NULL, chromaOut = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, source, NULL, MTLPixelFormatR8Unorm, width, height, 0, &lumaIn);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, output, NULL, MTLPixelFormatR8Unorm, width, height, 0, &lumaOut);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, source, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chromaIn);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, output, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chromaOut);
    BOOL ok = lumaIn && lumaOut && chromaIn && chromaOut;
    if (ok) {
        id<MTLCommandBuffer> commands = [_metalQueue commandBuffer];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        float amount = (float)self.sharpness;
        [compute setComputePipelineState:_sharpenPipeline];
        [compute setTexture:CVMetalTextureGetTexture(lumaIn) atIndex:0];
        [compute setTexture:CVMetalTextureGetTexture(lumaOut) atIndex:1];
        [compute setBytes:&amount length:sizeof(amount) atIndex:0];
        NSUInteger groupWidth = _sharpenPipeline.threadExecutionWidth, groupHeight = _sharpenPipeline.maxTotalThreadsPerThreadgroup / groupWidth;
        [compute dispatchThreadgroups:MTLSizeMake((width + groupWidth - 1) / groupWidth, (height + groupHeight - 1) / groupHeight, 1)
                threadsPerThreadgroup:MTLSizeMake(groupWidth, groupHeight, 1)];
        [compute endEncoding];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromTexture:CVMetalTextureGetTexture(chromaIn) toTexture:CVMetalTextureGetTexture(chromaOut)];
        [blit endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        ok = commands.error == nil;
        CVBufferPropagateAttachments(source, output);
    }
    if (lumaIn) CFRelease(lumaIn);
    if (lumaOut) CFRelease(lumaOut);
    if (chromaIn) CFRelease(chromaIn);
    if (chromaOut) CFRelease(chromaOut);
    if (!ok) { CVPixelBufferRelease(output); return NULL; }
    return output;
}

- (void)makeOutputWindow {
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    CGFloat width = MIN(1280, screen.size.width * 0.6), height = width * 9 / 16;
    NSRect rect = NSMakeRect(NSMaxX(screen) - width - 40, NSMaxY(screen) - height - 60, width, height);
    self.panel = [[OutputPanel alloc] initWithContentRect:rect
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                          NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = @"smooth-anything — double-click for full screen";
    self.panel.backgroundColor = NSColor.blackColor;
    self.panel.floatingPanel = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.contentAspectRatio = NSMakeSize(16, 9);
    self.panel.delegate = self;
    // Stays visible over a captured app that is itself in a full-screen Space.
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

    OutputView *view = [[OutputView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    __weak Smoother *weakSelf = self;
    view.toggleFullScreen = ^{ [weakSelf toggleFullScreen]; };
    view.isFullScreen = ^BOOL { Smoother *me = weakSelf; return me ? me->_fullScreen : NO; };
    view.wantsLayer = YES;
    view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    self.panel.contentView = view;

    _layer = [CALayer new];
    _layer.frame = view.bounds;
    _layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _layer.contentsGravity = kCAGravityResizeAspect;
    _layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    [view.layer addSublayer:_layer];
    CADisplayLink *link = [view displayLinkWithTarget:self selector:@selector(refresh:)];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    [self.panel orderFrontRegardless];
    if (getenv("SMOOTH_FULLSCREEN")) [self toggleFullScreen];   // for automated tests; users double-click or press F
}

// Full screen here is a borderless panel over the whole screen above the menu bar, not a macOS full-screen
// Space: entering a Space would activate this app and take controller input away from the captured one.
// It is a second panel because a titled window restyled as borderless kept its rounded corners.
- (void)toggleFullScreen {
    _fullScreen = !_fullScreen;
    NSView *view = _fullScreen ? self.panel.contentView : _fullPanel.contentView;
    if (_fullScreen) {
        NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
        if (!_fullPanel) {
            _fullPanel = [[OutputPanel alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                          backing:NSBackingStoreBuffered defer:NO];
            // Very slightly translucent on purpose. Behind a fully opaque panel the captured window counts as
            // hidden and its captures arrive in bursts about 100 ms apart, which shows as freezes around still
            // pictures such as menus (measured: ~100 delivery gaps over 40 ms in 16 s opaque, 1-3 at 0.999).
            // Marking the panel non-opaque without real translucency was not enough.
            _fullPanel.opaque = NO;
            _fullPanel.backgroundColor = NSColor.clearColor;
            _fullPanel.alphaValue = 0.999;
            _fullPanel.level = NSScreenSaverWindowLevel;
            _fullPanel.hidesOnDeactivate = NO;
            _fullPanel.hasShadow = NO;
            _fullPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        }
        self.panel.contentView = [NSView new];
        [_fullPanel setFrame:screen.frame display:NO];
        _fullPanel.contentView = view;
        [_fullPanel orderFrontRegardless];
        [self.panel orderOut:nil];
        [_fullPanel makeFirstResponder:view];
    } else {
        _fullPanel.contentView = [NSView new];
        self.panel.contentView = view;
        [self.panel orderFrontRegardless];
        [_fullPanel orderOut:nil];
        [self.panel makeFirstResponder:view];
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    exit(0);
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
    // A second repeat in a row must also be about as faint as the first; otherwise real motion that has just slowed
    // sharply (a fast pan coming to rest) would be dropped as two repeats and show as a short freeze.
    // After a still period the last real frame's difference says nothing about the next change (a cursor moving
    // in a menu after a page transition would be dropped as a faint repeat), so the reference is forgotten.
    double now = HostNow();
    if (now - _lastNewTime > 0.15) _lastNewMean = 0;
    BOOL refinement = NO;
    if (_repeatsInRow == 0) refinement = mean < kRepeatRatio * _lastNewMean;
    else if (_repeatsInRow == 1) refinement = mean < MAX(2.5 * _lastRepeatMean, 0.08 * _lastNewMean);
    BOOL duplicate = comparable && (identical || refinement);
    _repeatsInRow = duplicate ? _repeatsInRow + 1 : 0;
    if (duplicate) _lastRepeatMean = mean; else { _lastNewMean = mean; _lastNewTime = now; }
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
        if (target > _slotVsync + _period / 2) {
            [_pending addObject:item];
            // Nothing drains the queue while the display callback is paused (output not on a live display).
            while (_pending.count > 6) { [_pending removeObjectAtIndex:0]; _missed++; }
            return;
        }
        // The callback for this frame's refresh already ran; there is still time to commit for it directly.
        BOOL inTime = !_slotFilled && target > _slotVsync - _period / 2 && _slotVsync - HostNow() > kCommitLead - 0.001;
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
    double now = HostNow();
    if (self.logStalls && _lastPresent > 0 && now - _lastPresent > 0.12 && now - _lastPresent < 3.0) {
        fprintf(stderr, "output: nothing shown for %.0f ms\n", (now - _lastPresent) * 1000);
    }
    _lastPresent = now;
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

// Capture queue. Shows the last capture, which had been dropped as a repeat, now that the picture has come to rest.
- (void)showRestFrame {
    if (!_restFrame) return;
    double period, grid;
    @synchronized (_pending) { period = _period; grid = _slotVsync; }
    CVPixelBufferRef frameOut = [self upscaled:_restFrame];
    double earliest = grid + ceil((HostNow() + kCommitLead - grid) / period - 1e-6) * period;
    double target = MAX(_lastTarget + period, earliest);
    [self show:frameOut target:target];
    CVPixelBufferRelease(frameOut);
    _lastTarget = target;
    _restShown++;
    // It is now the picture on screen, so the next middle frame starts from it.
    CVPixelBufferRelease(_previousFrame);
    _previousFrame = _restFrame;
    _previousTime = _restTime;
    _restFrame = NULL;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || stream != _queueStream) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSNumber *status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!frame || status.integerValue != SCFrameStatusComplete) return;

    double captureTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
    double arrival = HostNow();
    @synchronized (_pending) { if (_slotVsync > 0) { _phaseSum += fmod(arrival - _slotVsync + 10.0, _period); _phaseCount++; } }
    if (_statsStart == 0) _statsStart = arrival;
    _captured++;
    _captureLagSum += arrival - captureTime;

    // A capture dropped as a repeat is kept until the next capture arrives. When the picture comes to rest (a
    // menu opening, a fade ending) its last captures are faint next to the transition before them and are all
    // dropped as repeats, and since nothing changes afterwards no later frame would ever replace them: the
    // output would stay on a slightly earlier picture. If no capture follows within 60 ms, the kept one is shown.
    NSUInteger generation = ++_captureGeneration;
    CVPixelBufferRelease(_restFrame);
    _restFrame = NULL;

    if ([self isDuplicate:frame]) {
        _duplicates++;
        _restFrame = CVPixelBufferRetain(frame);
        _restTime = captureTime;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), _queue, ^{
            if (self->_captureGeneration == generation) [self showRestFrame];
        });
    } else {
        _unique++;
        // Gaps of several seconds are a paused or static screen, not a stall.
        if (self.logStalls && _lastUniqueArrival > 0 && arrival - _lastUniqueArrival > 0.12 && arrival - _lastUniqueArrival < 3.0) {
            fprintf(stderr, "source: no new frame for %.0f ms\n", (arrival - _lastUniqueArrival) * 1000);
        }
        _lastUniqueArrival = arrival;
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
        // Half the source interval in whole refreshes: one refresh at 60 Hz, two at 120 Hz.
        double step = MAX(1.0, round(_sourceInterval / 2 / period)) * period;
        double afterPrevious = _lastTarget + step;
        double first = MAX(afterPrevious, refreshAtOrAfter(HostNow() + kCommitLead));
        if (middleOut) {
            BOOL behind = first > sourceRefresh + (1 + self.cushion) * step + period / 2;
            // A spare refresh of delay that has gone unused for 3 s is given back.
            BOOL spare = first > refreshAtOrAfter(HostNow() + kCommitLead + 0.003) + period / 2;
            _spareStreak = spare ? _spareStreak + 1 : 0;
            BOOL giveBack = !self.steady && _spareStreak >= 90;
            if (behind || giveBack) {
                CVPixelBufferRelease(middleOut);
                middleOut = NULL;
                _trims++;
                _spareStreak = 0;
            }
        }
        if (_lastTarget > 0 && gap < 0.100 && first > afterPrevious + period / 2) _holds += (int)llround((first - afterPrevious) / step);
        if (middleOut) {
            [self show:middleOut target:first];
            CVPixelBufferRelease(middleOut);
            first += step;
        }
        if (_scaler) {
            // The compositor snapshots the screen at the same point of every refresh, and a captured frame's
            // timestamp is one of those points. GPU work running across the next one made the compositor miss
            // refreshes (measured on screen), so the second upscale waits until that point has passed.
            double sinceComposite = fmod(HostNow() - captureTime, period);
            double untilComposite = period - sinceComposite;
            if (untilComposite < 0.010) usleep((useconds_t)((untilComposite + 0.002) * 1e6));
        }
        CVPixelBufferRef frameOut = [self upscaled:frame];   // off the critical path: the middle frame is already on its way
        first = MAX(first, refreshAtOrAfter(HostNow() + kCommitLead));
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
        if (self.debugDiff || getenv("SMOOTH_DEBUG")) fprintf(stderr, "sched: late commits %d, skipped middles %d, missed %d, rest frames %d, frame arrives %.1f ms after refresh\n",
                caught, _trims, missed, _restShown, phase * 1000);
        _restShown = 0;
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
    dispatch_async(dispatch_get_main_queue(), ^{ [self recoverFrom:stream]; });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Smoother *smoother = [Smoother new];
        // Default: sharpest picture and steadiest pacing (1080p, one spare refresh kept, 50 ms behind the source).
        smoother.upscale = YES;
        smoother.steady = YES;
        smoother.cushion = 1;
        smoother.cropTop = -1;
        smoother.logStalls = YES;
        smoother.sharpness = 1.5;   // chosen by eye on game frames: clearly crisper, while 2.5 starts to amplify compression noise
        double seconds = 0;
        BOOL lowLatency = NO, sharpnessGiven = NO;
        for (int i = 1; i < argc; i++) {
            NSString *flag = @(argv[i]);
            NSString *value = i + 1 < argc ? @(argv[i + 1]) : nil;
            if ([flag isEqual:@"--match"] && value) { smoother.match = value; i++; }
            // 720p; the spare refresh is given back whenever the source is steady (33-50 ms).
            else if ([flag isEqual:@"--no-upscale"]) { smoother.upscale = NO; smoother.steady = NO; }
            // 720p and no spare refresh at all: always 33 ms, at the price of a hold whenever a source frame is late.
            else if ([flag isEqual:@"--low-latency"]) { smoother.upscale = NO; smoother.steady = NO; smoother.cushion = 0; lowLatency = YES; }
            else if ([flag isEqual:@"--crop-top"] && value) { smoother.cropTop = value.doubleValue; i++; }
            else if ([flag isEqual:@"--sharpen"] && value) { smoother.sharpness = value.doubleValue; sharpnessGiven = YES; i++; }
            else if ([flag isEqual:@"--no-stalls"]) smoother.logStalls = NO;
            else if ([flag isEqual:@"--passthrough"]) smoother.passthrough = YES;
            else if ([flag isEqual:@"--debug-diff"]) smoother.debugDiff = YES;
            else if ([flag isEqual:@"--seconds"] && value) { seconds = value.doubleValue; i++; }
            else { fprintf(stderr, "Unknown or incomplete option: %s\n", argv[i]); return 2; }
        }
        // Sharpening takes 1-2 ms, which the 33 ms schedule cannot always spare.
        if (lowLatency && !sharpnessGiven) smoother.sharpness = 0;
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        NSMenu *bar = [NSMenu new], *menu = [NSMenu new];
        [menu addItemWithTitle:@"Quit smooth-anything" action:@selector(terminate:) keyEquivalent:@"q"];
        [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:menu];
        app.mainMenu = bar;
        if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
        [smoother start];
        if (seconds > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        }
        [app run];
    }
    return 0;
}
