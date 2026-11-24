#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "smooth.h"

static const NSInteger kProcessWidth = 1280, kProcessHeight = 720;
static const OSType kProcessFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
static const double kCommitLead = 0.013;
static const double kRepeatRatio = 0.3;

static double HostNow(void) { return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())); }
static CMTime HostTime(double seconds) { return CMTimeMakeWithSeconds(seconds, 1000000000); }

static CVPixelBufferPoolRef NewPool(NSDictionary *base, NSInteger width, NSInteger height) {
    NSMutableDictionary *attributes = [base mutableCopy] ?: [NSMutableDictionary dictionary];
    attributes[(id)kCVPixelBufferWidthKey] = @(width);
    attributes[(id)kCVPixelBufferHeightKey] = @(height);
    attributes[(id)kCVPixelBufferPixelFormatTypeKey] = @(kProcessFormat);
    attributes[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    attributes[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &pool);
    return pool;
}

@interface Smoother : NSObject
- (void)submit:(CVPixelBufferRef)frame;
- (void)hide;
@end

@implementation Smoother {
    dispatch_queue_t _queue;
    BOOL _debug, _debugDiff, _prepared;
    double _sharpness, _maxMotion, _coarseMotion;
    int _failed;

    VTFrameProcessor *_processor, *_coarseProcessor;
    CVPixelBufferPoolRef _middlePool, _canvasPool;
    dispatch_queue_t _coarseQueue;
    id<MTLComputePipelineState> _shrinkLuma, _shrinkChroma, _mergeLuma, _mergeChroma, _weightMap;
    id<MTLTexture> _weights;
    CVPixelBufferRef _previousCanvas;
    BOOL _coarse;
    VTFrameProcessor *_scaler;
    CVPixelBufferPoolRef _scaledPool;
    VTPixelTransferSessionRef _transfer;
    CVPixelBufferPoolRef _smallPool;

    id<MTLDevice> _device;
    id<MTLCommandQueue> _commands;
    CVMetalTextureCacheRef _textures, _presentTextures;
    id<MTLComputePipelineState> _sharpenPipeline;
    CVPixelBufferPoolRef _sharpPool;
    size_t _sharpWidth;
    id<MTLRenderPipelineState> _presentPipeline;
    CAMetalLayer *_layer;
    NSObject *_presentLock;

    NSWindow *_host;
    NSPanel *_child;
    BOOL _attached, _hidden;

    NSMutableArray *_pending;
    int _shown, _missed;
    double _slotVsync, _period;
    BOOL _slotFilled;

    CVPixelBufferRef _previousFrame;
    double _previousTime;
    uint8_t *_previousSamples;
    size_t _sampleCount;
    int _repeatsInRow;
    double _lastNewMean, _lastRepeatMean, _lastNewTime, _motionLevel;
    BOOL _sceneCut;
    CVPixelBufferRef _restFrame, _restNative;
    double _restTime;
    NSUInteger _generation;

    double _sourceInterval, _lastTarget;

    double _statsStart, _interpSum, _scaleSum, _delaySum, _coarseShare;
    int _received, _unique, _interpolated, _scaled, _cuts, _holds, _skipped, _delayCount;
}

- (instancetype)init {
    self = [super init];
    _queue = dispatch_queue_create("smooth.frames", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _presentLock = [NSObject new];
    _pending = [NSMutableArray array];
    _period = 1.0 / 60.0;
    _sourceInterval = 1.0 / 30.0;
    _debug = getenv("SMOOTH_DEBUG") != NULL;
    _debugDiff = getenv("SMOOTH_DIFF") != NULL;
    _sharpness = getenv("SMOOTH_SHARPEN") ? atof(getenv("SMOOTH_SHARPEN")) : 0;
    _maxMotion = getenv("SMOOTH_MAX_MOTION") ? atof(getenv("SMOOTH_MAX_MOTION")) : 255;
    _coarseMotion = getenv("SMOOTH_COARSE_MOTION") ? atof(getenv("SMOOTH_COARSE_MOTION")) : 6;
    _coarse = _coarseMotion < 255;
    _coarseQueue = dispatch_queue_create("smooth.coarse", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _device = MTLCreateSystemDefaultDevice();
    _commands = [_device newCommandQueue];
    CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_textures);
    CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_presentTextures);
    return self;
}

- (void)prepare {
    if (_prepared) return;
    _prepared = YES;
    if ([VTLowLatencyFrameInterpolationConfiguration isSupported]) {
        VTLowLatencyFrameInterpolationConfiguration *config =
            [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:kProcessWidth frameHeight:kProcessHeight numberOfInterpolatedFrames:1];
        VTFrameProcessor *processor = [VTFrameProcessor new];
        NSError *error = nil;
        if (config && [processor startSessionWithConfiguration:config error:&error]) {
            _processor = processor;
            _middlePool = NewPool(config.destinationPixelBufferAttributes, kProcessWidth, kProcessHeight);
            VTFrameProcessor *coarse = [VTFrameProcessor new];
            if (_coarse && [coarse startSessionWithConfiguration:config error:nil] && [self prepareCoarse]) _coarseProcessor = coarse;
        } else {
            fprintf(stderr, "smooth: interpolation unavailable: %s\n", error.description.UTF8String);
        }
    }
    if ([VTLowLatencySuperResolutionScalerConfiguration isSupported]) {
        NSArray<NSNumber *> *factors = [VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:kProcessWidth frameHeight:kProcessHeight];
        if ([factors containsObject:@1.5f]) {
            VTLowLatencySuperResolutionScalerConfiguration *config =
                [[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:kProcessWidth frameHeight:kProcessHeight scaleFactor:1.5f];
            VTFrameProcessor *scaler = [VTFrameProcessor new];
            if ([scaler startSessionWithConfiguration:config error:nil]) {
                _scaler = scaler;
                _scaledPool = NewPool(config.destinationPixelBufferAttributes, kProcessWidth * 3 / 2, kProcessHeight * 3 / 2);
            }
        }
    }
    VTPixelTransferSessionCreate(NULL, &_transfer);
    _smallPool = NewPool(nil, kProcessWidth, kProcessHeight);

    CVPixelBufferRef blankA = NULL, blankB = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _smallPool, &blankA);
    CVPixelBufferPoolCreatePixelBuffer(NULL, _smallPool, &blankB);
    for (int round = 0; round < 2 && blankA && blankB; round++) {
        CVPixelBufferRelease([self interpolateFrom:blankA at:0 to:blankB at:1.0 / 30 with:_coarseProcessor]);
        CVPixelBufferRef middle = [self interpolateFrom:blankA at:0 to:blankB at:1.0 / 30 with:_processor];
        CVPixelBufferRef finished = [self finished:middle ?: blankB large:YES];
        CVPixelBufferRelease(finished);
        CVPixelBufferRelease(middle);
    }
    CVPixelBufferRelease(blankA);
    CVPixelBufferRelease(blankB);
    _failed = 0;
    _scaleSum = 0;
    _scaled = 0;
}

- (CVPixelBufferRef)interpolateFrom:(CVPixelBufferRef)previous at:(double)previousTime to:(CVPixelBufferRef)current at:(double)currentTime
                             with:(VTFrameProcessor *)processor {
    if (!processor) return NULL;
    CVPixelBufferRef destination = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _middlePool, &destination);
    if (!destination) return NULL;
    CVBufferPropagateAttachments(current, destination);
    VTFrameProcessorFrame *source = [[VTFrameProcessorFrame alloc] initWithBuffer:current presentationTimeStamp:HostTime(currentTime)];
    VTFrameProcessorFrame *reference = [[VTFrameProcessorFrame alloc] initWithBuffer:previous presentationTimeStamp:HostTime(previousTime)];
    VTFrameProcessorFrame *output = [[VTFrameProcessorFrame alloc] initWithBuffer:destination presentationTimeStamp:HostTime((previousTime + currentTime) / 2)];
    VTLowLatencyFrameInterpolationParameters *parameters = (source && reference && output) ?
        [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:source previousFrame:reference
                                                           interpolationPhase:@[@0.5f] destinationFrames:@[output]] : nil;
    NSError *error = nil;
    if (!parameters || ![processor processWithParameters:parameters error:&error]) {
        if (_failed++ == 0) fprintf(stderr, "smooth: interpolation failed: %s\n", error ? error.description.UTF8String : "frames rejected");
        CVPixelBufferRelease(destination);
        return NULL;
    }
    return destination;
}

- (BOOL)prepareCoarse {
    static NSString *const shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);\n"
        "kernel void shrinkLuma(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
        "                       uint2 gid [[thread_position_in_grid]]) {\n"
        "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
        "    float2 size = float2(dst.get_width(), dst.get_height());\n"
        "    bool inside = gid.x < dst.get_width() / 2 && gid.y < dst.get_height() / 2;\n"
        "    float v = inside ? src.sample(s, (float2(gid) * 2.0 + 1.0) / size).r : 16.0 / 255.0;\n"
        "    dst.write(float4(v, 0, 0, 1), gid);\n"
        "}\n"
        "kernel void shrinkChroma(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
        "                         uint2 gid [[thread_position_in_grid]]) {\n"
        "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
        "    float2 size = float2(dst.get_width(), dst.get_height());\n"
        "    bool inside = gid.x < dst.get_width() / 2 && gid.y < dst.get_height() / 2;\n"
        "    float2 v = inside ? src.sample(s, (float2(gid) * 2.0 + 1.0) / size).rg : float2(0.5);\n"
        "    dst.write(float4(v, 0, 1), gid);\n"
        "}\n"
        "kernel void weightMap(texture2d<float, access::sample> fine [[texture(0)]], texture2d<float, access::sample> coarse [[texture(1)]],\n"
        "                      texture2d<float, access::sample> prev [[texture(2)]], texture2d<float, access::sample> cur [[texture(3)]],\n"
        "                      texture2d<float, access::write> dst [[texture(4)]], constant float &everywhere [[buffer(0)]],\n"
        "                      uint2 gid [[thread_position_in_grid]]) {\n"
        "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
        "    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());\n"
        "    float2 px = 1.0 / float2(fine.get_width(), fine.get_height());\n"
        "    float differs = 0, moved = 0;\n"
        "    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {\n"
        "        float2 p = uv + float2(x, y) * 12.0 * px;\n"
        "        differs = max(differs, abs(fine.sample(s, p).r - coarse.sample(s, p * 0.5).r));\n"
        "        moved = max(moved, abs(prev.sample(s, p).r - cur.sample(s, p).r));\n"
        "    }\n"
        "    float w = max(smoothstep(0.025, 0.06, differs), everywhere) * smoothstep(0.012, 0.04, moved);\n"
        "    dst.write(float4(w, 0, 0, 1), gid);\n"
        "}\n"
        "kernel void mergeLuma(texture2d<float, access::sample> fine [[texture(0)]], texture2d<float, access::sample> coarse [[texture(1)]],\n"
        "                      texture2d<float, access::sample> map [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],\n"
        "                      uint2 gid [[thread_position_in_grid]]) {\n"
        "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
        "    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());\n"
        "    dst.write(float4(mix(fine.sample(s, uv).r, coarse.sample(s, uv * 0.5).r, map.sample(s, uv).r), 0, 0, 1), gid);\n"
        "}\n"
        "kernel void mergeChroma(texture2d<float, access::sample> fine [[texture(0)]], texture2d<float, access::sample> coarse [[texture(1)]],\n"
        "                        texture2d<float, access::sample> map [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],\n"
        "                        uint2 gid [[thread_position_in_grid]]) {\n"
        "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
        "    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());\n"
        "    dst.write(float4(mix(fine.sample(s, uv).rg, coarse.sample(s, uv * 0.5).rg, map.sample(s, uv).r), 0, 1), gid);\n"
        "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:shader options:nil error:&error];
    id<MTLComputePipelineState> (^pipeline)(NSString *) = ^id<MTLComputePipelineState>(NSString *name) {
        id<MTLFunction> function = [library newFunctionWithName:name];
        return function ? [self->_device newComputePipelineStateWithFunction:function error:nil] : nil;
    };
    _shrinkLuma = pipeline(@"shrinkLuma");
    _shrinkChroma = pipeline(@"shrinkChroma");
    _mergeLuma = pipeline(@"mergeLuma");
    _mergeChroma = pipeline(@"mergeChroma");
    _weightMap = pipeline(@"weightMap");
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:kProcessWidth / 4 height:kProcessHeight / 4 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;
    _weights = [_device newTextureWithDescriptor:descriptor];
    _canvasPool = NewPool(nil, kProcessWidth, kProcessHeight);
    BOOL ok = _shrinkLuma && _shrinkChroma && _mergeLuma && _mergeChroma && _weightMap && _weights && _canvasPool;
    if (!ok) fprintf(stderr, "smooth: coarse interpolation unavailable: %s\n", error.localizedDescription.UTF8String);
    return ok;
}

- (void)dispatch:(id<MTLComputeCommandEncoder>)compute pipeline:(id<MTLComputePipelineState>)pipeline width:(size_t)width height:(size_t)height {
    NSUInteger groupWidth = pipeline.threadExecutionWidth, groupHeight = pipeline.maxTotalThreadsPerThreadgroup / groupWidth;
    [compute setComputePipelineState:pipeline];
    [compute dispatchThreadgroups:MTLSizeMake((width + groupWidth - 1) / groupWidth, (height + groupHeight - 1) / groupHeight, 1)
            threadsPerThreadgroup:MTLSizeMake(groupWidth, groupHeight, 1)];
}

- (BOOL)textures:(CVMetalTextureRef *)luma :(CVMetalTextureRef *)chroma of:(CVPixelBufferRef)buffer {
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textures, buffer, NULL, MTLPixelFormatR8Unorm, width, height, 0, luma);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textures, buffer, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, chroma);
    return *luma && *chroma;
}

- (CVPixelBufferRef)shrunk:(CVPixelBufferRef)frame {
    if (!_coarseProcessor) return NULL;
    CVPixelBufferRef canvas = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _canvasPool, &canvas);
    if (!canvas) return NULL;
    CVMetalTextureRef luma[2] = {NULL}, chroma[2] = {NULL};
    BOOL ok = [self textures:&luma[0] :&chroma[0] of:frame] && [self textures:&luma[1] :&chroma[1] of:canvas];
    if (ok) {
        id<MTLCommandBuffer> commands = [_commands commandBuffer];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        [compute setTexture:CVMetalTextureGetTexture(luma[0]) atIndex:0];
        [compute setTexture:CVMetalTextureGetTexture(luma[1]) atIndex:1];
        [self dispatch:compute pipeline:_shrinkLuma width:kProcessWidth height:kProcessHeight];
        [compute setTexture:CVMetalTextureGetTexture(chroma[0]) atIndex:0];
        [compute setTexture:CVMetalTextureGetTexture(chroma[1]) atIndex:1];
        [self dispatch:compute pipeline:_shrinkChroma width:kProcessWidth / 2 height:kProcessHeight / 2];
        [compute endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        ok = commands.error == nil;
        CVBufferPropagateAttachments(frame, canvas);
    }
    for (int i = 0; i < 2; i++) { if (luma[i]) CFRelease(luma[i]); if (chroma[i]) CFRelease(chroma[i]); }
    if (!ok) { CVPixelBufferRelease(canvas); return NULL; }
    return canvas;
}

- (float)disagreementOf:(CVPixelBufferRef)fine with:(CVPixelBufferRef)coarse {
    CVPixelBufferLockBaseAddress(fine, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(coarse, kCVPixelBufferLock_ReadOnly);
    const uint8_t *f = CVPixelBufferGetBaseAddressOfPlane(fine, 0), *c = CVPixelBufferGetBaseAddressOfPlane(coarse, 0);
    size_t fs = CVPixelBufferGetBytesPerRowOfPlane(fine, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(coarse, 0);
    long differing = 0, total = 0;
    for (size_t y = 8; y + 1 < (size_t)kProcessHeight; y += 8) for (size_t x = 8; x + 1 < (size_t)kProcessWidth; x += 8) {
        int average = (f[y * fs + x] + f[y * fs + x + 1] + f[(y + 1) * fs + x] + f[(y + 1) * fs + x + 1] + 2) / 4;
        if (abs(average - (int)c[(y / 2) * cs + x / 2]) > 14) differing++;
        total++;
    }
    CVPixelBufferUnlockBaseAddress(fine, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(coarse, kCVPixelBufferLock_ReadOnly);
    return total ? (float)differing / total : 0;
}

- (CVPixelBufferRef)merged:(CVPixelBufferRef)fine with:(CVPixelBufferRef)coarse between:(CVPixelBufferRef)previous and:(CVPixelBufferRef)current {
    CVPixelBufferRef output = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _canvasPool, &output);
    if (!output) return NULL;
    float share = [self disagreementOf:fine with:coarse];
    float everywhere = MIN(1.0f, MAX(0.0f, (share - 0.04f) / 0.06f));
    _coarseShare += share;
    CVPixelBufferRef buffers[5] = {fine, coarse, previous, current, output};
    CVMetalTextureRef luma[5] = {NULL}, chroma[5] = {NULL};
    BOOL ok = YES;
    for (int i = 0; i < 5; i++) ok = [self textures:&luma[i] :&chroma[i] of:buffers[i]] && ok;
    if (ok) {
        id<MTLCommandBuffer> commands = [_commands commandBuffer];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        for (int i = 0; i < 4; i++) [compute setTexture:CVMetalTextureGetTexture(luma[i]) atIndex:i];
        [compute setTexture:_weights atIndex:4];
        [compute setBytes:&everywhere length:sizeof(everywhere) atIndex:0];
        [self dispatch:compute pipeline:_weightMap width:kProcessWidth / 4 height:kProcessHeight / 4];
        [compute setTexture:_weights atIndex:2];
        [compute setTexture:CVMetalTextureGetTexture(luma[4]) atIndex:3];
        [self dispatch:compute pipeline:_mergeLuma width:kProcessWidth height:kProcessHeight];
        [compute setTexture:CVMetalTextureGetTexture(chroma[0]) atIndex:0];
        [compute setTexture:CVMetalTextureGetTexture(chroma[1]) atIndex:1];
        [compute setTexture:CVMetalTextureGetTexture(chroma[4]) atIndex:3];
        [self dispatch:compute pipeline:_mergeChroma width:kProcessWidth / 2 height:kProcessHeight / 2];
        [compute endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        ok = commands.error == nil;
        CVBufferPropagateAttachments(fine, output);
    }
    for (int i = 0; i < 5; i++) { if (luma[i]) CFRelease(luma[i]); if (chroma[i]) CFRelease(chroma[i]); }
    if (!ok) { CVPixelBufferRelease(output); return NULL; }
    return output;
}

- (CVPixelBufferRef)finished:(CVPixelBufferRef)buffer large:(BOOL)large {
    double begin = HostNow();
    CVPixelBufferRef result = CVPixelBufferRetain(buffer);
    if (large && _scaler) {
        CVPixelBufferRef destination = NULL;
        CVPixelBufferPoolCreatePixelBuffer(NULL, _scaledPool, &destination);
        if (destination) {
            CVBufferPropagateAttachments(buffer, destination);
            VTFrameProcessorFrame *source = [[VTFrameProcessorFrame alloc] initWithBuffer:buffer presentationTimeStamp:HostTime(begin)];
            VTFrameProcessorFrame *output = [[VTFrameProcessorFrame alloc] initWithBuffer:destination presentationTimeStamp:HostTime(begin)];
            VTLowLatencySuperResolutionScalerParameters *parameters = (source && output) ?
                [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:source destinationFrame:output] : nil;
            if (parameters && [_scaler processWithParameters:parameters error:nil]) {
                CVPixelBufferRelease(result);
                result = destination;
            } else {
                CVPixelBufferRelease(destination);
            }
        }
    }
    if (_sharpness > 0) {
        CVPixelBufferRef sharper = [self sharpened:result];
        if (sharper) { CVPixelBufferRelease(result); result = sharper; }
    }
    if (result != buffer) { _scaleSum += HostNow() - begin; _scaled++; }
    return result;
}

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
    if (!_sharpenPipeline) {
        id<MTLLibrary> library = [_device newLibraryWithSource:shader options:nil error:nil];
        id<MTLFunction> function = [library newFunctionWithName:@"sharpen"];
        _sharpenPipeline = function ? [_device newComputePipelineStateWithFunction:function error:nil] : nil;
    }
    if (!_sharpenPipeline) return NULL;
    if (!_sharpPool || _sharpWidth != width) {
        CVPixelBufferPoolRelease(_sharpPool);
        _sharpPool = NewPool(nil, width, height);
        _sharpWidth = width;
    }
    CVPixelBufferRef output = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _sharpPool, &output);
    if (!output) return NULL;
    CVMetalTextureRef lumaIn = NULL, lumaOut = NULL, chromaIn = NULL, chromaOut = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textures, source, NULL, MTLPixelFormatR8Unorm, width, height, 0, &lumaIn);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textures, output, NULL, MTLPixelFormatR8Unorm, width, height, 0, &lumaOut);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textures, source, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chromaIn);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textures, output, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chromaOut);
    BOOL ok = lumaIn && lumaOut && chromaIn && chromaOut;
    if (ok) {
        id<MTLCommandBuffer> commands = [_commands commandBuffer];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        float amount = (float)_sharpness;
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

- (void)attach {
    NSWindow *host = nil;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible || [window isKindOfClass:NSPanel.class] || !window.contentView) continue;
        if (!host || window.frame.size.width * window.frame.size.height > host.frame.size.width * host.frame.size.height) host = window;
    }
    if (!host) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self attach]; });
        return;
    }
    NSRect content = [host convertRectToScreen:host.contentLayoutRect];
    NSPanel *child = [[NSPanel alloc] initWithContentRect:content styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered defer:NO];
    child.backgroundColor = NSColor.blackColor;
    child.ignoresMouseEvents = YES;
    child.hasShadow = NO;
    child.hidesOnDeactivate = NO;
    child.releasedWhenClosed = NO;
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, content.size.width, content.size.height)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    child.contentView = view;
    [host addChildWindow:child ordered:NSWindowAbove];
    _host = host;
    _child = child;
    if (_hidden) [child orderOut:nil];
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification,
                                      NSWindowDidChangeScreenNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:host queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [child setFrame:[host convertRectToScreen:host.contentLayoutRect] display:YES];
        }];
    }
    [self startOutputIn:view];
}

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
        "    return float4(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x, 1.0);\n"
        "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:shader options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"fullscreen"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"ycbcr"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _presentPipeline = library ? [_device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!_presentPipeline) { fprintf(stderr, "smooth: cannot set up the output: %s\n", error.localizedDescription.UTF8String); return; }

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.displaySyncEnabled = NO;
    layer.maximumDrawableCount = 3;
    layer.allowsNextDrawableTimeout = YES;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    layer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    layer.frame = view.bounds;
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    layer.contentsGravity = kCAGravityResizeAspect;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    layer.drawableSize = CGSizeMake(kProcessWidth * 3 / 2, kProcessHeight * 3 / 2);
    [view.layer addSublayer:layer];
    @synchronized (_presentLock) { _layer = layer; }

    CADisplayLink *link = [view displayLinkWithTarget:self selector:@selector(refresh:)];
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
        [NSRunLoop.currentRunLoop run];
    }];
    thread.name = @"smooth.display";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
}

- (void)hide {
    _hidden = YES;
    [_child orderOut:nil];
}

- (void)unhide {
    if (!_hidden) return;
    _hidden = NO;
    if (_child && !_child.parentWindow) [_host addChildWindow:_child ordered:NSWindowAbove];
    [_child orderFront:nil];
}

- (BOOL)isDuplicate:(CVPixelBufferRef)buffer {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
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
            uint8_t value = row[x * step];
            int difference = comparable ? abs((int)value - (int)_previousSamples[index]) : 0;
            total += (uint64_t)difference;
            if (difference >= 8) strong++;
            _previousSamples[index] = value;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    double mean = (double)total / (double)count;
    double now = HostNow();
    if (now - _lastNewTime > 0.15) _lastNewMean = 0;
    BOOL identical = mean < 0.01 && strong == 0;
    BOOL refinement = NO;
    if (_repeatsInRow == 0) refinement = mean < kRepeatRatio * _lastNewMean;
    else if (_repeatsInRow == 1) refinement = mean < MAX(2.5 * _lastRepeatMean, 0.08 * _lastNewMean);
    BOOL duplicate = comparable && (identical || refinement);
    _repeatsInRow = duplicate ? _repeatsInRow + 1 : 0;
    if (duplicate) _lastRepeatMean = mean; else { _lastNewMean = mean; _lastNewTime = now; }
    _sceneCut = comparable && !duplicate && mean > 12.0 && mean > 2.5 * _motionLevel;
    if (!duplicate) _motionLevel += 0.2 * (mean - _motionLevel);
    if (_debugDiff) fprintf(stderr, "diff mean %.3f strong %d %s\n", mean, strong, duplicate ? "repeat" : _sceneCut ? "cut" : "new");
    return duplicate;
}

- (void)show:(CVPixelBufferRef)buffer target:(double)target {
    NSArray *item = @[(__bridge id)buffer, @(target)];
    @synchronized (_pending) {
        if (target > _slotVsync + _period / 2) {
            NSUInteger index = _pending.count;
            while (index > 0 && [_pending[index - 1][1] doubleValue] > target) index--;
            [_pending insertObject:item atIndex:index];
            while (_pending.count > 6) { [_pending removeObjectAtIndex:0]; _missed++; }
            return;
        }
        BOOL inTime = !_slotFilled && target > _slotVsync - _period / 2 && _slotVsync - HostNow() > kCommitLead - 0.001;
        if (!inTime) {
            if (_pending.count == 0) [_pending addObject:@[(__bridge id)buffer, @(_slotVsync + _period)]];
            else _missed++;
            return;
        }
        _slotFilled = YES;
        _shown++;
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

- (void)present:(NSArray *)item {
    @synchronized (_presentLock) {
        if (!_layer) return;
        CVPixelBufferRef buffer = (__bridge CVPixelBufferRef)item[0];
        size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
        if (!CVPixelBufferIsPlanar(buffer)) return;
        if (_layer.drawableSize.width != width || _layer.drawableSize.height != height) _layer.drawableSize = CGSizeMake(width, height);
        CVMetalTextureRef luma = NULL, chroma = NULL;
        CVMetalTextureCacheCreateTextureFromImage(NULL, _presentTextures, buffer, NULL, MTLPixelFormatR8Unorm, width, height, 0, &luma);
        CVMetalTextureCacheCreateTextureFromImage(NULL, _presentTextures, buffer, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chroma);
        id<CAMetalDrawable> drawable = (luma && chroma) ? [_layer nextDrawable] : nil;
        if (!drawable) {
            if (luma) CFRelease(luma);
            if (chroma) CFRelease(chroma);
            return;
        }
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> commands = [_commands commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
        float fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0;
        [encoder setRenderPipelineState:_presentPipeline];
        [encoder setFragmentTexture:CVMetalTextureGetTexture(luma) atIndex:0];
        [encoder setFragmentTexture:CVMetalTextureGetTexture(chroma) atIndex:1];
        [encoder setFragmentBytes:&fullRange length:sizeof(fullRange) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [commands presentDrawable:drawable];
        [commands addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)item; CFRelease(luma); CFRelease(chroma); }];
        [commands commit];
    }
}

- (double)refreshAtOrAfter:(double)time {
    double period, grid;
    @synchronized (_pending) { period = _period; grid = _slotVsync; }
    return grid + ceil((time - grid) / period - 1e-6) * period;
}

- (void)showRest {
    if (!_restFrame) return;
    double target = MAX(_lastTarget + _period, [self refreshAtOrAfter:HostNow() + kCommitLead]);
    [self show:_restNative target:target];
    _lastTarget = target;
    CVPixelBufferRelease(_previousFrame);
    _previousFrame = _restFrame;
    _previousTime = _restTime;
    CVPixelBufferRelease(_previousCanvas);
    _previousCanvas = [self shrunk:_restFrame];
    _restFrame = NULL;
    CVPixelBufferRelease(_restNative);
    _restNative = NULL;
}

- (void)handle:(CVPixelBufferRef)native small:(CVPixelBufferRef)small received:(double)received {
    if (_statsStart == 0) _statsStart = received;
    _received++;
    NSUInteger generation = ++_generation;
    CVPixelBufferRelease(_restFrame);
    _restFrame = NULL;
    CVPixelBufferRelease(_restNative);
    _restNative = NULL;

    if ([self isDuplicate:small]) {
        _restFrame = CVPixelBufferRetain(small);
        _restNative = CVPixelBufferRetain(native);
        _restTime = received;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), _queue, ^{
            if (self->_generation == generation) [self showRest];
        });
    } else {
        _unique++;
        if (_sceneCut) _cuts++;
        double gap = _previousFrame ? received - _previousTime : 0;
        if (gap > 0.025 && gap < 0.045) _sourceInterval += 0.1 * (gap - _sourceInterval);
        double period;
        @synchronized (_pending) { period = _period; }

        CVPixelBufferRef canvas = [self shrunk:small];
        CVPixelBufferRef middleOut = NULL;
        if (_previousFrame && gap < 0.100 && !_sceneCut && _lastNewMean <= _maxMotion) {
            double begin = HostNow();
            __block CVPixelBufferRef coarse = NULL;
            dispatch_group_t group = dispatch_group_create();
            if (canvas && _previousCanvas && _lastNewMean > _coarseMotion) {
                CVPixelBufferRef previousCanvas = _previousCanvas;
                double previousTime = _previousTime;
                dispatch_group_async(group, _coarseQueue, ^{
                    coarse = [self interpolateFrom:previousCanvas at:previousTime to:canvas at:received with:self->_coarseProcessor];
                });
            }
            CVPixelBufferRef middle = [self interpolateFrom:_previousFrame at:_previousTime to:small at:received with:_processor];
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
            if (middle && coarse) {
                CVPixelBufferRef merged = [self merged:middle with:coarse between:_previousFrame and:small];
                if (merged) { CVPixelBufferRelease(middle); middle = merged; }
            }
            CVPixelBufferRelease(coarse);
            _interpSum += HostNow() - begin;
            if (middle) {
                _interpolated++;
                BOOL large = CVPixelBufferGetWidth(native) == (size_t)kProcessWidth * 3 / 2 && CVPixelBufferGetHeight(native) == (size_t)kProcessHeight * 3 / 2;
                middleOut = [self finished:middle large:large];
                CVPixelBufferRelease(middle);
            }
        }

        double step = MAX(1.0, round(_sourceInterval / 2 / period)) * period;
        double afterPrevious = _lastTarget + step;
        double earliest = [self refreshAtOrAfter:HostNow() + kCommitLead];
        if (afterPrevious > earliest + 2 * step + period / 2) afterPrevious = earliest;
        double first = MAX(MAX(afterPrevious, earliest), [self refreshAtOrAfter:received] + 2 * step);
        if (middleOut && first - received > 3 * step + period / 2) {
            CVPixelBufferRelease(middleOut);
            middleOut = NULL;
            _skipped++;
        }
        if (_lastTarget > 0 && gap < 0.100 && first > afterPrevious + period / 2) _holds += (int)llround((first - afterPrevious) / step);
        if (middleOut) {
            [self show:middleOut target:first];
            CVPixelBufferRelease(middleOut);
            first += step;
        }
        first = MAX(first, [self refreshAtOrAfter:HostNow() + kCommitLead]);
        [self show:native target:first];
        _lastTarget = first;
        _delaySum += first - received;
        _delayCount++;
        CVPixelBufferRelease(_previousFrame);
        _previousFrame = CVPixelBufferRetain(small);
        _previousTime = received;
        CVPixelBufferRelease(_previousCanvas);
        _previousCanvas = canvas;
    }

    double elapsed = received - _statsStart;
    if (elapsed < 2.0) return;
    if (_debug) {
        int shown, missed;
        @synchronized (_pending) { shown = _shown; missed = _missed; _shown = _missed = 0; }
        fprintf(stderr, "smooth: in %.1f fps (unique %.1f) | out %.1f fps | held %d, skipped %d, missed %d, cuts %d | "
                "interp %.1f ms, upscale %.1f ms | delay %.1f ms | coarse %.0f%%\n",
                _received / elapsed, _unique / elapsed, shown / elapsed, _holds, _skipped, missed, _cuts,
                _interpolated ? _interpSum / _interpolated * 1000 : 0, _scaled ? _scaleSum / _scaled * 1000 : 0,
                _delayCount ? _delaySum / _delayCount * 1000 : 0, _interpolated ? _coarseShare / _interpolated * 100 : 0);
    } else {
        @synchronized (_pending) { _shown = _missed = 0; }
    }
    _statsStart = received;
    _received = _unique = _interpolated = _scaled = _cuts = _holds = _skipped = _delayCount = 0;
    _interpSum = _scaleSum = _delaySum = _coarseShare = 0;
}

- (void)submit:(CVPixelBufferRef)frame {
    double received = HostNow();
    CVPixelBufferRetain(frame);
    if (!_attached) {
        _attached = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ [self attach]; });
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self unhide]; });
    dispatch_async(_queue, ^{
        [self prepare];
        OSType format = CVPixelBufferGetPixelFormatType(frame);
        BOOL showable = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        BOOL fits = format == kProcessFormat && CVPixelBufferGetWidth(frame) == (size_t)kProcessWidth && CVPixelBufferGetHeight(frame) == (size_t)kProcessHeight;
        CVPixelBufferRef small = NULL;
        if (fits) {
            small = CVPixelBufferRetain(frame);
        } else {
            CVPixelBufferPoolCreatePixelBuffer(NULL, self->_smallPool, &small);
            if (small && VTPixelTransferSessionTransferImage(self->_transfer, frame, small) != noErr) { CVPixelBufferRelease(small); small = NULL; }
        }
        if (small) [self handle:(showable ? frame : small) small:small received:received];
        CVPixelBufferRelease(small);
        CVPixelBufferRelease(frame);
    });
}
@end

static Smoother *Shared(void) {
    static Smoother *smoother;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ smoother = [Smoother new]; });
    return smoother;
}

void SmoothSubmit(CVPixelBufferRef frame) {
    [Shared() submit:frame];
}

void SmoothHide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [Shared() hide]; });
}
