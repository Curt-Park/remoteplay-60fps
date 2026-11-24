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
@property BOOL passThrough;   // inside a host window: every event goes to the host's own view underneath
@property (copy) void (^toggleFullScreen)(void);
@property (copy) BOOL (^isFullScreen)(void);
@end

@implementation OutputView
- (NSView *)hitTest:(NSPoint)point { return self.passThrough ? nil : [super hitTest:point]; }
- (BOOL)acceptsFirstResponder { return !self.passThrough; }
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
@property BOOL embedded;          // fed by a host application: no picker, and closing the window does not quit
@property BOOL logStalls;         // print gaps of 0.12-3 s in source frames and in shown frames
@property double cropTop;         // points cut from the top of the captured window; negative = automatic
@property BOOL debugDiff;
@property NSInteger cushion;   // extra refreshes of delay allowed for absorbing uneven frame arrival
@property BOOL steady;         // keep the extra refresh once it is in use instead of giving it back
@property BOOL upscale;   // super-resolve every shown frame 1.5x after interpolation
@property NSInteger interpolationWidth, interpolationHeight;   // 0 = the capture size
@property NSPanel *panel;
@end

@implementation Smoother {
    SCStream *_stream;
    dispatch_queue_t _queue;
    CAMetalLayer *_layer;
    id<MTLDevice> _presentDevice;
    id<MTLCommandQueue> _presentQueue;
    id<MTLRenderPipelineState> _presentPipeline;
    CVMetalTextureCacheRef _presentCache;
    NSObject *_presentLock;
    VTFrameProcessor *_processor;
    CVPixelBufferPoolRef _pool;
    // Interpolating at a size other than the capture's: captures are scaled into _largePool, middles come out of
    // _largeMiddlePool and are scaled back into _pool. The last enlarged capture is kept for the next pair.
    VTPixelTransferSessionRef _transfer;
    CVPixelBufferPoolRef _largePool, _largeMiddlePool;
    CVPixelBufferRef _largeCache, _largeCacheSource;
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
    double _interpSum, _interpMax, _captureLagSum, _scaleSum;   // _scaleSum and _scaled are guarded by @synchronized(_pending)
    int _scaled;
    dispatch_queue_t _upscaleQueue;   // real frames' upscaling, beside the capture queue
    double _frameUpscaleEstimate;     // guarded by @synchronized(_pending)
    double _recentUpscales[8];
    unsigned _recentUpscaleIndex;
    int _resyncs, _lateShown;
    BOOL _warmedUp;
    BOOL _outputHidden;   // main thread
    NSWindow *_hostWindow;
    NSPanel *_hostChild;
    VTPixelTransferSessionRef _submitTransfer;
    CVPixelBufferPoolRef _submitPool;
    NSObject *_sharpenLock;
    CGWindowID _currentWindowID;
    BOOL _waitingReported;
    int _repeatsInRow, _restShown;
    NSUInteger _captureGeneration;
    CVPixelBufferRef _restFrame;
    CVPixelBufferRef _restNative;      // the same picture at the source's own size, when the host supplied one
    CVPixelBufferRef _currentNative;   // set only while a submitted frame is being handled
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
    _upscaleQueue = dispatch_queue_create("smooth-anything.upscale", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _frameUpscaleEstimate = 0.008;
    _sharpenLock = [NSObject new];
    _presentLock = [NSObject new];
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
        CVPixelBufferRelease(self->_largeCache);
        CVPixelBufferRelease(self->_largeCacheSource);
        self->_largeCache = self->_largeCacheSource = NULL;
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

    __block OSType pixelFormat = 0;
    dispatch_sync(_queue, ^{ pixelFormat = [self prepareSessions]; });

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
// Capture queue. Starts the interpolator and scaler once and returns the pixel format frames must have.
- (OSType)prepareSessions {
    NSInteger width = kProcessWidth, height = kProcessHeight;
    OSType pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (!self.passthrough) {
        OSType chosen = _processor ? _processorFormat : [self startInterpolatorWidth:width height:height];
        if (chosen) { pixelFormat = chosen; _processorFormat = chosen; }
    }
    if (self.upscale && !_scaler) [self startScalerWidth:width height:height format:pixelFormat];
    [self warmUpWidth:width height:height format:pixelFormat];
    return pixelFormat;
}

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

static CVPixelBufferPoolRef NewPool(NSDictionary *base, NSInteger width, NSInteger height, OSType format) {
    NSMutableDictionary *attributes = [base mutableCopy];
    attributes[(id)kCVPixelBufferWidthKey] = @(width);
    attributes[(id)kCVPixelBufferHeightKey] = @(height);
    attributes[(id)kCVPixelBufferPixelFormatTypeKey] = @(format);
    attributes[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &pool);
    return pool;
}

- (OSType)startInterpolatorWidth:(NSInteger)width height:(NSInteger)height {
    if (![VTLowLatencyFrameInterpolationConfiguration isSupported]) {
        fprintf(stderr, "Low-latency frame interpolation is not supported on this Mac.\n");
        exit(1);
    }
    // Above 1280x720's pixels the interpolator runs a slower network whose middle frames are closer to the real ones
    // (measured on an M2 Pro: +2.4 dB at 1284x722 for 720p frames, 12 -> 20 ms a call).
    NSInteger interpWidth = self.interpolationWidth ?: width, interpHeight = self.interpolationHeight ?: height;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000   // these are declared from the macOS 27 SDK on
    NSInteger maxPixels = [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
    NSInteger maxDimension = [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
    fprintf(stderr, "Interpolator limits: %ld pixels, %ld max dimension (request is %ld pixels)\n",
            (long)maxPixels, (long)maxDimension, (long)(interpWidth * interpHeight));
#endif
    VTLowLatencyFrameInterpolationConfiguration *config =
        [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:interpWidth frameHeight:interpHeight numberOfInterpolatedFrames:1];
    if (!config) {
        fprintf(stderr, "Interpolator rejected %ldx%ld; showing frames without interpolation.\n", (long)interpWidth, (long)interpHeight);
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
    fprintf(stderr, "Interpolator ready at %ldx%ld in %.0f ms\n", (long)interpWidth, (long)interpHeight, (HostNow() - begin) * 1000);

    BOOL scaled = interpWidth != width || interpHeight != height;
    // Middles scaled back to the capture size must not inherit the interpolator's padding (above 1280x720 it asks for
    // extended pixels), which made the super-resolution scaler crash.
    _pool = NewPool(scaled ? @{} : config.destinationPixelBufferAttributes, width, height, chosen);
    if (scaled) {
        VTPixelTransferSessionCreate(NULL, &_transfer);
        _largePool = NewPool(config.sourcePixelBufferAttributes, interpWidth, interpHeight, chosen);
        _largeMiddlePool = NewPool(config.destinationPixelBufferAttributes, interpWidth, interpHeight, chosen);
    }
    return chosen;
}

// Returns a retained copy of a capture at the interpolation size, or NULL.
- (CVPixelBufferRef)enlarged:(CVPixelBufferRef)buffer {
    CVPixelBufferRef large = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _largePool, &large);
    if (!large) return NULL;
    CVBufferPropagateAttachments(buffer, large);
    if (VTPixelTransferSessionTransferImage(_transfer, buffer, large) != noErr) { CVPixelBufferRelease(large); return NULL; }
    return large;
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

// The first call into each model takes 100 ms or more (measured 156 ms for super resolution). Paying that on
// blank frames before capture starts keeps it out of the schedule of the first real frames.
- (void)warmUpWidth:(NSInteger)width height:(NSInteger)height format:(OSType)format {
    if (_warmedUp) return;
    _warmedUp = YES;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferRef blankA = NULL, blankB = NULL;
    CVPixelBufferCreate(NULL, width, height, format, (__bridge CFDictionaryRef)attributes, &blankA);
    CVPixelBufferCreate(NULL, width, height, format, (__bridge CFDictionaryRef)attributes, &blankB);
    if (blankA && blankB) {
        for (int round = 0; round < 2; round++) {
            if (_processor) [self interpolateFrom:blankA at:0 to:blankB at:1.0 / 30 phases:@[@0.5f] with:_processor];
            CVPixelBufferRelease([self upscaled:blankB]);
        }
    }
    CVPixelBufferRelease(blankA);
    CVPixelBufferRelease(blankB);
    _failed = 0;
    _scaleSum = 0;
    _scaled = 0;
}

// Returns a retained buffer: the super-resolved frame, or the input itself when scaling is off or fails.
// Returns a retained frame ready for display: super-resolved when upscaling is on, then sharpened.
- (CVPixelBufferRef)upscaled:(CVPixelBufferRef)buffer {
    double begin = HostNow();
    CVPixelBufferRef result = [self superResolved:buffer];
    if (self.sharpness > 0) {
        CVPixelBufferRef sharper = NULL;
        @synchronized (_sharpenLock) { sharper = [self sharpened:result]; }   // called from the capture and upscale queues
        if (sharper) { CVPixelBufferRelease(result); result = sharper; }
    }
    if (result != buffer) {
        double took = HostNow() - begin;
        @synchronized (_pending) { _scaleSum += took; _scaled++; }
    }
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

// Frames are drawn into a Metal layer and presented from a thread of their own. Presents queue up and
// reach the screen one per refresh in order, whatever else the application is doing. The earlier path,
// setting a plain layer's contents, depended on commits from the main thread landing in the right
// refresh: inside a Qt host about 40 % of frames never reached the screen (measured), and the same
// commits made from another thread lost half of them even in the standalone tool.
- (void)startOutputIn:(NSView *)view {
    static NSString *const shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Out { float4 position [[position]]; float2 uv; };\n"
        "vertex Out fullscreen(uint id [[vertex_id]]) {\n"
        "    float2 p = float2((id << 1) & 2, id & 2);\n"
        "    Out o; o.position = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;\n"
        "}\n"
        "fragment float4 ycbcr(Out in [[stage_in]], texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],\n"
        "                      constant float &fullRange [[buffer(0)]]) {\n"
        "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
        "    float y = luma.sample(s, in.uv).r;\n"
        "    float2 c = chroma.sample(s, in.uv).rg - 0.5;\n"
        "    if (fullRange < 0.5) { y = (y - 16.0 / 255.0) * (255.0 / 219.0); c *= 255.0 / 224.0; }\n"
        "    return float4(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x, 1.0);\n"   // BT.709
        "}\n";
    _presentDevice = MTLCreateSystemDefaultDevice();
    _presentQueue = [_presentDevice newCommandQueue];
    NSError *error = nil;
    id<MTLLibrary> library = [_presentDevice newLibraryWithSource:shader options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"fullscreen"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"ycbcr"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _presentPipeline = library ? [_presentDevice newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!_presentPipeline) { fprintf(stderr, "Cannot set up the output: %s\n", error.localizedDescription.UTF8String); exit(1); }
    CVMetalTextureCacheCreate(NULL, NULL, _presentDevice, NULL, &_presentCache);

    _layer = [CAMetalLayer layer];
    _layer.device = _presentDevice;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    // Not synchronised to the display: a synchronised layer queues presents, and after one late frame the queue
    // stayed full, so every present blocked for a refresh and the display callback fell behind (measured 36-42 ms).
    // The display callback already presents once per refresh.
    _layer.displaySyncEnabled = NO;
    _layer.maximumDrawableCount = 3;
    _layer.allowsNextDrawableTimeout = YES;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    _layer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    _layer.frame = view.bounds;
    _layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _layer.contentsGravity = kCAGravityResizeAspect;
    _layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    _layer.drawableSize = CGSizeMake(kProcessWidth * 3 / 2, kProcessHeight * 3 / 2);
    [view.layer addSublayer:_layer];

    CADisplayLink *link = [view displayLinkWithTarget:self selector:@selector(refresh:)];
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
        [NSRunLoop.currentRunLoop run];
    }];
    thread.name = @"smooth-anything.display";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
}

// Embedded: the picture is laid over the content of the host application's own window, so the host keeps its
// window management, full screen and input handling.
- (void)attachToHostWindow {
    NSWindow *host = nil;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible || [window isKindOfClass:NSPanel.class] || !window.contentView) continue;
        if (!host || window.frame.size.width * window.frame.size.height > host.frame.size.width * host.frame.size.height) host = window;
    }
    if (!host) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self attachToHostWindow]; });
        return;
    }
    // A borderless child window over the host's content rather than a view inside it: as a view above the
    // host's own Metal layer only about 35 of every 60 presented frames reached the screen (measured).
    NSRect content = [host convertRectToScreen:host.contentLayoutRect];
    NSPanel *child = [[OutputPanel alloc] initWithContentRect:content styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                      backing:NSBackingStoreBuffered defer:NO];
    child.backgroundColor = NSColor.blackColor;
    child.ignoresMouseEvents = YES;   // every event goes to the host's own view underneath
    child.hasShadow = NO;
    child.hidesOnDeactivate = NO;
    child.releasedWhenClosed = NO;
    OutputView *view = [[OutputView alloc] initWithFrame:NSMakeRect(0, 0, content.size.width, content.size.height)];
    view.passThrough = YES;
    view.wantsLayer = YES;
    view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    child.contentView = view;
    [host addChildWindow:child ordered:NSWindowAbove];
    _hostWindow = host;
    _hostChild = child;
    if (_outputHidden) [child orderOut:nil];
    // A child window follows its parent when it moves, but not when it is resized or changes screen.
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification,
                                      NSWindowDidChangeScreenNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:host queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [child setFrame:[host convertRectToScreen:host.contentLayoutRect] display:YES];
        }];
    }
    [self startOutputIn:view];
    fprintf(stderr, "smooth-anything: showing in the host window (%.0fx%.0f pt)\n", view.bounds.size.width, view.bounds.size.height);
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

    [self startOutputIn:view];

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
    if (!self.embedded) exit(0);
}

- (void)hideOutput {
    _outputHidden = YES;
    if (self.embedded) { [_hostChild orderOut:nil]; return; }
    if (_fullScreen) [self toggleFullScreen];
    [self.panel orderOut:nil];
}

- (void)showOutputIfHidden {
    if (!_outputHidden) return;
    _outputHidden = NO;
    if (self.embedded) { if (_hostChild && !_hostChild.parentWindow) [_hostWindow addChildWindow:_hostChild ordered:NSWindowAbove]; [_hostChild orderFront:nil]; return; }
    [self.panel orderFrontRegardless];
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
    // A display faster than the source delivers the same picture again; that copy says nothing about the source's
    // cadence, so it does not count toward the repeats in a row (on 120 Hz, re-encodes were taken as new frames).
    if (comparable && identical) {
        _sceneCut = NO;
        if (self.debugDiff) fprintf(stderr, "diff mean %.3f strong %d identical\n", mean, strong);
        return YES;
    }
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
            // Kept in target order: a real frame upscaled on its own queue can arrive after a later middle frame.
            NSUInteger index = _pending.count;
            while (index > 0 && [_pending[index - 1][1] doubleValue] > target) index--;
            [_pending insertObject:item atIndex:index];
            // Nothing drains the queue while the display callback is paused (output not on a live display).
            while (_pending.count > 6) { [_pending removeObjectAtIndex:0]; _missed++; }
            return;
        }
        // The callback for this frame's refresh already ran; there is still time to commit for it directly.
        BOOL inTime = !_slotFilled && target > _slotVsync - _period / 2 && _slotVsync - HostNow() > kCommitLead - 0.001;
        if (!inTime) {
            // Too late for its own refresh. Showing it one refresh late beats dropping it, unless a newer frame is due then.
            if (_pending.count == 0) { [_pending addObject:@[(__bridge id)buffer, @(_slotVsync + _period)]]; _lateShown++; }
            else _missed++;
            return;
        }
        _slotFilled = YES;
        _shown++;
        _caught++;
    }
    [self present:item];
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

// Display thread, or the thread that just finished a frame in time for the current refresh.
// Draws the frame into the next drawable and presents it; the system shows it at the coming refresh.
- (void)present:(NSArray *)item {
    @synchronized (_presentLock) {
        double now = HostNow();
        if (self.logStalls && _lastPresent > 0 && now - _lastPresent > 0.12 && now - _lastPresent < 3.0) {
            fprintf(stderr, "output: nothing shown for %.0f ms\n", (now - _lastPresent) * 1000);
        }
        _lastPresent = now;
        CVPixelBufferRef buffer = (__bridge CVPixelBufferRef)item[0];
        size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
        if (!CVPixelBufferIsPlanar(buffer)) return;
        if (_layer.drawableSize.width != width || _layer.drawableSize.height != height) _layer.drawableSize = CGSizeMake(width, height);
        CVMetalTextureRef luma = NULL, chroma = NULL;
        CVMetalTextureCacheCreateTextureFromImage(NULL, _presentCache, buffer, NULL, MTLPixelFormatR8Unorm, width, height, 0, &luma);
        CVMetalTextureCacheCreateTextureFromImage(NULL, _presentCache, buffer, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chroma);
        id<CAMetalDrawable> drawable = (luma && chroma) ? [_layer nextDrawable] : nil;
        if (drawable) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = drawable.texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> commands = [_presentQueue commandBuffer];
            id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
            float fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0;
            [encoder setRenderPipelineState:_presentPipeline];
            [encoder setFragmentTexture:CVMetalTextureGetTexture(luma) atIndex:0];
            [encoder setFragmentTexture:CVMetalTextureGetTexture(chroma) atIndex:1];
            [encoder setFragmentBytes:&fullRange length:sizeof(fullRange) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
            [commands presentDrawable:drawable];
            // The frame and its textures must outlive the GPU's use of them.
            [commands addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)item; CFRelease(luma); CFRelease(chroma); }];
            [commands commit];
        } else {
            if (luma) CFRelease(luma);
            if (chroma) CFRelease(chroma);
        }
    }
}

// Returns the frames at the given phases between the two inputs, oldest first, or nil on failure.
- (NSArray *)interpolateFrom:(CVPixelBufferRef)previous at:(double)previousTime to:(CVPixelBufferRef)current at:(double)currentTime
                      phases:(NSArray<NSNumber *> *)phases with:(VTFrameProcessor *)processor {
    if (!_transfer) return [self interpolatePair:previous at:previousTime to:current at:currentTime phases:phases with:processor into:_pool];
    CVPixelBufferRef largePrevious = previous == _largeCacheSource && _largeCache ? CVPixelBufferRetain(_largeCache) : [self enlarged:previous];
    CVPixelBufferRef largeCurrent = [self enlarged:current];
    NSArray *large = largePrevious && largeCurrent ?
        [self interpolatePair:largePrevious at:previousTime to:largeCurrent at:currentTime phases:phases with:processor into:_largeMiddlePool] : nil;
    if (largeCurrent) {
        CVPixelBufferRelease(_largeCache);
        CVPixelBufferRelease(_largeCacheSource);
        _largeCache = CVPixelBufferRetain(largeCurrent);
        _largeCacheSource = CVPixelBufferRetain(current);
    }
    CVPixelBufferRelease(largePrevious);
    CVPixelBufferRelease(largeCurrent);
    if (!large) return nil;
    NSMutableArray *scaled = [NSMutableArray array];
    for (id frame in large) {
        CVPixelBufferRef small = NULL;
        CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &small);
        if (!small) return nil;
        [scaled addObject:(__bridge_transfer id)small];
        CVBufferPropagateAttachments((__bridge CVPixelBufferRef)frame, small);
        if (VTPixelTransferSessionTransferImage(_transfer, (__bridge CVPixelBufferRef)frame, small) != noErr) return nil;
    }
    return scaled;
}

- (NSArray *)interpolatePair:(CVPixelBufferRef)previous at:(double)previousTime to:(CVPixelBufferRef)current at:(double)currentTime
                      phases:(NSArray<NSNumber *> *)phases with:(VTFrameProcessor *)processor into:(CVPixelBufferPoolRef)pool {
    NSMutableArray *buffers = [NSMutableArray array];
    NSMutableArray<VTFrameProcessorFrame *> *outputs = [NSMutableArray array];
    for (NSNumber *phase in phases) {
        CVPixelBufferRef destination = NULL;
        CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &destination);
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
    CVPixelBufferRef frameOut = _restNative ? CVPixelBufferRetain(_restNative) : [self upscaled:_restFrame];
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
    CVPixelBufferRelease(_restNative);
    _restNative = NULL;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || stream != _queueStream) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSNumber *status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!frame || status.integerValue != SCFrameStatusComplete) return;

    [self handleFrame:frame capturedAt:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
}

// Capture queue. `frame` is at the processing size; `captureTime` is when the source showed it, or received it.
- (void)handleFrame:(CVPixelBufferRef)frame capturedAt:(double)captureTime {
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
    CVPixelBufferRelease(_restNative);
    _restNative = NULL;

    if ([self isDuplicate:frame]) {
        _duplicates++;
        _restFrame = CVPixelBufferRetain(frame);
        _restNative = CVPixelBufferRetain(_currentNative);
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
        double earliest = refreshAtOrAfter(HostNow() + kCommitLead);
        // After a stall the old timeline can sit far ahead of what is feasible now. Catching up by skipping
        // middle frames takes a refresh per frame and shows nothing meanwhile, so the timeline restarts instead.
        if (afterPrevious > earliest + 2 * step + period / 2) { afterPrevious = earliest; _resyncs++; }
        double first = MAX(afterPrevious, earliest);
        // In steady mode the delay is fixed rather than found: the middle frame never goes out before the spare
        // refresh has passed. Left to settle on its own the schedule drifted between two and three refreshes, and the
        // two-refresh stretches relied on frames presented outside the display callback, which showed less evenly
        // on screen (51 changes a second against 59).
        if (self.steady) first = MAX(first, sourceRefresh + (1 + self.cushion) * step);
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
        double wait = 0;
        if (_scaler && !_currentNative) {
            // The compositor snapshots the screen at the same point of every refresh, and a captured frame's
            // timestamp is one of those points. GPU work running across the next one made the compositor miss
            // refreshes (measured on screen), so the second upscale waits until that point has passed.
            double sinceComposite = fmod(HostNow() - captureTime, period);
            double untilComposite = period - sinceComposite;
            if (untilComposite < 0.010) wait = untilComposite + 0.002;
        }
        if (_currentNative) {
            // The host's frame is already at full size and sharper than anything rebuilt from the processing copy.
            first = MAX(first, refreshAtOrAfter(HostNow() + kCommitLead));
            [self show:_currentNative target:first];
        } else if (!_scaler && self.sharpness <= 0) {
            first = MAX(first, refreshAtOrAfter(HostNow() + kCommitLead));
            [self show:frame target:first];
        } else {
            // The real frame is upscaled on a queue of its own, beside the next pair's interpolation (measured: neither
            // slowed the other), so the capture queue keeps up with a slower interpolation. Its refresh is chosen now,
            // from how long an upscale has taken.
            double estimate;
            @synchronized (_pending) { estimate = _frameUpscaleEstimate; }
            first = MAX(first, refreshAtOrAfter(HostNow() + wait + estimate + 0.002 + kCommitLead));
            double target = first, start = HostNow() + wait;
            CVPixelBufferRetain(frame);
            dispatch_async(_upscaleQueue, ^{
                double delay = start - HostNow();
                if (delay > 0) usleep((useconds_t)(delay * 1e6));
                double begin = HostNow();
                CVPixelBufferRef frameOut = [self upscaled:frame];
                double took = HostNow() - begin;
                @synchronized (self->_pending) {
                    // The slowest of the last eight, capped: a single hiccup is forgotten in a quarter of a second
                    // and can never push the schedule back by more than two refreshes.
                    self->_recentUpscales[self->_recentUpscaleIndex++ % 8] = took;
                    double slowest = 0;
                    for (int i = 0; i < 8; i++) slowest = MAX(slowest, self->_recentUpscales[i]);
                    self->_frameUpscaleEstimate = MIN(slowest, 0.030);
                }
                [self show:frameOut target:target];
                CVPixelBufferRelease(frameOut);
                CVPixelBufferRelease(frame);
            });
        }
        _lastTarget = first;
        _behindSum += first - sourceRefresh;
        _behindCount++;
        CVPixelBufferRelease(_previousFrame);
        _previousFrame = CVPixelBufferRetain(frame);
        _previousTime = captureTime;
    }

    double elapsed = arrival - _statsStart;
    if (elapsed >= 2.0) {
        int shown, caught, missed, scaled;
        double phase, scaleSum;
        @synchronized (_pending) {
            shown = _shown; caught = _caught; missed = _missed; phase = _phaseCount ? _phaseSum / _phaseCount : 0;
            scaled = _scaled; scaleSum = _scaleSum;
            _shown = _caught = _missed = 0; _phaseSum = 0; _phaseCount = 0;
            _scaled = 0; _scaleSum = 0;
        }
        fprintf(stderr, "in %.1f fps (unique %.1f, repeats %.1f) | out %.1f fps, held refreshes %d, cuts %d | interp avg %.1f ms max %.1f ms | "
                "upscale avg %.1f ms | behind source window %.1f ms\n",
                _captured / elapsed, _unique / elapsed, _duplicates / elapsed, shown / elapsed, _holds, _cuts,
                _interpolated ? _interpSum / _interpolated * 1000 : 0, _interpMax * 1000,
                scaled ? scaleSum / scaled * 1000 : 0,
                _behindCount ? _behindSum / _behindCount * 1000 : 0);
        if (self.debugDiff || getenv("SMOOTH_DEBUG")) fprintf(stderr, "sched: late commits %d, skipped middles %d, missed %d, shown late %d, resyncs %d, rest frames %d, frame arrives %.1f ms after refresh\n",
                caught, _trims, missed, _lateShown, _resyncs, _restShown, phase * 1000);
        _lateShown = _resyncs = 0;
        _restShown = 0;
        _holds = _trims = _behindCount = 0;
        _behindSum = 0;
        _statsStart = arrival;
        _captured = _unique = _duplicates = _interpolated = _cuts = 0;
        _interpSum = _interpMax = _captureLagSum = 0;
    }
}

// Any thread. Takes a decoded frame straight from a host application instead of capturing a window.
// Frames of another size are scaled to the processing size for interpolation, and shown at their own size.
- (void)submit:(CVPixelBufferRef)frame {
    double received = HostNow();
    CVPixelBufferRetain(frame);
    dispatch_async(_queue, ^{
        OSType format = [self prepareSessions];
        CVPixelBufferRef sized = NULL;
        BOOL fits = CVPixelBufferGetWidth(frame) == (size_t)kProcessWidth && CVPixelBufferGetHeight(frame) == (size_t)kProcessHeight &&
                    CVPixelBufferGetPixelFormatType(frame) == format;
        if (fits) {
            sized = CVPixelBufferRetain(frame);
        } else {
            if (!self->_submitTransfer) {
                VTPixelTransferSessionCreate(NULL, &self->_submitTransfer);
                self->_submitPool = NewPool(@{}, kProcessWidth, kProcessHeight, format);
                fprintf(stderr, "Scaling %zux%zu frames to %ldx%ld for processing\n", CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame),
                        (long)kProcessWidth, (long)kProcessHeight);
            }
            CVPixelBufferPoolCreatePixelBuffer(NULL, self->_submitPool, &sized);
            if (sized && VTPixelTransferSessionTransferImage(self->_submitTransfer, frame, sized) != noErr) { CVPixelBufferRelease(sized); sized = NULL; }
        }
        // Only the middle frames need the processing size. Real frames are shown as the host decoded them.
        OSType sourceFormat = CVPixelBufferGetPixelFormatType(frame);
        BOOL showable = sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        self->_currentNative = (!fits && showable && !getenv("SMOOTH_NO_NATIVE")) ? frame : NULL;
        if (sized) [self handleFrame:sized capturedAt:received];
        self->_currentNative = NULL;
        CVPixelBufferRelease(sized);
        CVPixelBufferRelease(frame);
    });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(stderr, "Capture stopped (%s); looking for the window again.\n", error.localizedDescription.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{ [self recoverFrom:stream]; });
}
@end

// Default: sharpest picture and steadiest pacing (1080p, one spare refresh kept).
static Smoother *NewSmoother(void) {
    Smoother *smoother = [Smoother new];
    smoother.upscale = YES;
    smoother.steady = YES;
    smoother.cushion = 1;
    smoother.cropTop = -1;
    smoother.logStalls = YES;
    smoother.sharpness = 1.5;   // chosen by eye on game frames: clearly crisper, while 2.5 starts to amplify compression noise
    return smoother;
}

#ifdef SMOOTH_EMBEDDED

// Entry points for a host application that feeds decoded frames itself (see smooth.h).
static Smoother *gEmbedded;

void SmoothSubmit(CVPixelBufferRef frame) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Smoother *smoother = NewSmoother();
        smoother.embedded = YES;
        if (getenv("SMOOTH_NO_UPSCALE")) { smoother.upscale = NO; smoother.steady = NO; }
        if (getenv("SMOOTH_SHARPEN")) smoother.sharpness = atof(getenv("SMOOTH_SHARPEN"));
        gEmbedded = smoother;
        dispatch_async(dispatch_get_main_queue(), ^{ [smoother attachToHostWindow]; });
    });
    [gEmbedded submit:frame];
    dispatch_async(dispatch_get_main_queue(), ^{ [gEmbedded showOutputIfHidden]; });
}

void SmoothHide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [gEmbedded hideOutput]; });
}

#else

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Smoother *smoother = NewSmoother();
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
            else if ([flag isEqual:@"--interp-size"] && value) {
                NSArray<NSString *> *parts = [value componentsSeparatedByString:@"x"];
                if (parts.count != 2 || parts[0].integerValue < 64 || parts[1].integerValue < 64) { fprintf(stderr, "--interp-size takes WxH\n"); return 2; }
                smoother.interpolationWidth = parts[0].integerValue & ~1;
                smoother.interpolationHeight = parts[1].integerValue & ~1;
                i++;
            }
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

#endif
