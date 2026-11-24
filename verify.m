#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>

@interface Meter : NSObject <SCStreamOutput, SCStreamDelegate>
@property NSString *match;
@property double seconds;
@end

@implementation Meter {
    SCStream *_stream;
    dispatch_queue_t _queue;
    uint8_t *_previousSamples;
    size_t _sampleCount;
    NSMutableArray<NSNumber *> *_differences;
    double _firstTime;
    double _rate;
}

- (void)start {
    _queue = dispatch_queue_create("verify.frames", DISPATCH_QUEUE_SERIAL);
    _differences = [NSMutableArray array];
    _rate = NSScreen.mainScreen.maximumFramesPerSecond > 0 ? NSScreen.mainScreen.maximumFramesPerSecond : 60;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        if (!content) {
            fprintf(stderr, "Cannot list windows: %s\nGrant Screen Recording permission to your terminal in "
                    "System Settings > Privacy & Security, then run again.\n", error.localizedDescription.UTF8String);
            exit(1);
        }
        SCWindow *best = nil;
        for (SCWindow *window in content.windows) {
            SCRunningApplication *app = window.owningApplication;
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ pid:%d", app.applicationName, app.bundleIdentifier, app.processID];
            if ([haystack rangeOfString:self.match options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            if (window.frame.size.width < 200 || window.frame.size.height < 150) continue;
            if (!best || window.frame.size.width * window.frame.size.height > best.frame.size.width * best.frame.size.height) best = window;
        }
        if (!best) { fprintf(stderr, "No on-screen window matching \"%s\".\n", self.match.UTF8String); exit(1); }
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = 640;
        config.height = 360;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.minimumFrameInterval = CMTimeMake(1, 240);
        config.queueDepth = 8;
        config.showsCursor = NO;
        self->_stream = [[SCStream alloc] initWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:best]
                                           configuration:config delegate:self];
        NSError *outputError = nil;
        if (![self->_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_queue error:&outputError]) {
            fprintf(stderr, "Cannot attach to the capture: %s\n", outputError.localizedDescription.UTF8String);
            exit(1);
        }
        [self->_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) { fprintf(stderr, "Capture failed: %s\n", startError.localizedDescription.UTF8String); exit(1); }
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((self.seconds + 1) * NSEC_PER_SEC)), self->_queue, ^{ [self report]; });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSInteger status = [[attachments.firstObject objectForKey:SCStreamFrameInfoStatus] integerValue];
    double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
    if (_firstTime == 0) _firstTime = time;
    NSInteger slot = (NSInteger)llround((time - _firstTime - 1.0) * _rate);
    while (slot >= 0 && (NSInteger)_differences.count <= slot && _differences.count < 3600) [_differences addObject:@0];
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!buffer || status != SCFrameStatusComplete) return;

    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    size_t step = 4, count = (width / step) * (height / step), index = 0;
    BOOL comparable = _previousSamples && _sampleCount == count;
    if (!comparable) { free(_previousSamples); _previousSamples = malloc(count); _sampleCount = count; }
    uint64_t total = 0;
    for (size_t y = 0; y < height / step; y++) {
        for (size_t x = 0; x < width / step; x++, index++) {
            uint8_t value = base[y * step * stride + x * step * 4 + 1];
            if (comparable) total += (uint64_t)abs((int)value - (int)_previousSamples[index]);
            _previousSamples[index] = value;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (comparable && slot >= 0 && slot < (NSInteger)_differences.count) {
        _differences[slot] = @(_differences[slot].doubleValue + (double)total / (double)count);
    }
}

- (void)report {
    NSUInteger refreshes = _differences.count;
    if (refreshes < 60) { fprintf(stderr, "Too few frames captured (%lu).\n", (unsigned long)refreshes); exit(1); }
    NSArray<NSNumber *> *sorted = [_differences sortedArrayUsingSelector:@selector(compare:)];
    double typicalMotion = sorted[refreshes * 3 / 4].doubleValue;
    double threshold = MAX(0.02, typicalMotion * 0.25);
    NSUInteger moved = 0, pairs = 0, evenPairs = 0;
    for (NSUInteger i = 0; i < refreshes; i++) if (_differences[i].doubleValue >= threshold) moved++;
    for (NSUInteger i = 0; i + 1 < refreshes; i += 2) {
        double first = _differences[i].doubleValue, second = _differences[i + 1].doubleValue;
        double larger = MAX(first, second), smaller = MIN(first, second);
        if (larger < threshold) continue;
        pairs++;
        if (smaller >= 0.4 * larger) evenPairs++;
    }
    double duration = refreshes / _rate;
    printf("%s: measured %.1f s at the display rate\n", self.match.UTF8String, duration);
    printf("  refreshes showing new motion: %.1f per second\n", moved / duration);
    printf("  motion split evenly across both refreshes of a pair: %.0f%% of pairs\n", pairs ? 100.0 * evenPairs / pairs : 0);
    NSUInteger held[6] = {0}, run = 0, pictures = 0;
    for (NSUInteger i = 0; i < refreshes; i++) {
        BOOL changed = _differences[i].doubleValue >= threshold;
        if (changed && run > 0) { held[MIN(run, (NSUInteger)5)]++; pictures++; }
        run = changed ? 1 : (run > 0 ? run + 1 : 0);
    }
    printf("  refreshes each picture stayed up:");
    for (NSUInteger length = 1; length <= 5; length++) {
        printf(" %lu%s: %.0f%%", (unsigned long)length, length == 5 ? "+" : "", pictures ? 100.0 * held[length] / pictures : 0);
    }
    printf("\n");
    printf("  first 40 refresh differences:");
    for (NSUInteger i = 0; i < 40 && i < refreshes; i++) printf(" %.1f", _differences[i].doubleValue);
    printf("\n");
    exit(0);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(stderr, "Capture stopped: %s\n", error.localizedDescription.UTF8String);
    exit(1);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Meter *meter = [Meter new];
        meter.seconds = 8;
        for (int i = 1; i + 1 < argc; i += 2) {
            if (!strcmp(argv[i], "--match")) meter.match = @(argv[i + 1]);
            else if (!strcmp(argv[i], "--seconds")) meter.seconds = atof(argv[i + 1]);
        }
        if (!meter.match) { fprintf(stderr, "usage: verify --match <app> [--seconds N]\n"); return 2; }
        NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyAccessory;
        [meter start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((meter.seconds + 6) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            fprintf(stderr, "No result; the window delivered no frames.\n");
            exit(1);
        });
        [NSApp run];
    }
    return 0;
}
