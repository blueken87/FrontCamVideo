#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>

static NSString *const kIGFDirName = @"FrontCam";
static NSString *const kIGFLogName = @"FrontCam.log";

static NSString *IGFDocumentsDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kIGFDirName];
}

static void IGFLog(NSString *message) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *manager = [NSFileManager defaultManager];
        NSArray *directories = @[
            [@"/var/jb/var/mobile/Documents" stringByAppendingPathComponent:kIGFDirName],
            [@"/var/mobile/Documents" stringByAppendingPathComponent:kIGFDirName],
            IGFDocumentsDirectory()
        ];
        for (NSString *directory in directories) {
            [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *path = [directory stringByAppendingPathComponent:kIGFLogName];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle closeFile];
            } else if ([data writeToFile:path atomically:NO]) {
                break;
            }
        }
    } @catch (NSException *exception) { }
}

static NSUserDefaults *IGFDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.bluek.frontcam"];
}

static BOOL IGFEnabled(void) {
    NSNumber *value = [IGFDefaults() objectForKey:@"Enabled"];
    return value ? value.boolValue : YES;
}

static BOOL IGFMirror(void) {
    NSNumber *value = [IGFDefaults() objectForKey:@"Mirror"];
    return value ? value.boolValue : YES;
}

static NSString *IGFFindVideoInDirectory(NSString *directory) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *files = [manager contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *name in files) {
        NSString *lower = name.lowercaseString;
        if ([lower isEqualToString:@"frontcam.mp4"] || [lower isEqualToString:@"frontcam.mov"] ||
            [lower isEqualToString:@"video.mp4"] || [lower isEqualToString:@"video.mov"]) {
            return [directory stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

static NSString *IGFVideoPath(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *configured = [IGFDefaults() stringForKey:@"Path"];
    if (configured.length && [manager fileExistsAtPath:configured]) {
        BOOL isDirectory = NO;
        if ([manager fileExistsAtPath:configured isDirectory:&isDirectory] && isDirectory) {
            NSString *found = IGFFindVideoInDirectory(configured);
            if (found) return found;
        } else {
            return configured;
        }
    }

    NSArray *directories = @[
        [@"/var/jb/var/mobile/Documents" stringByAppendingPathComponent:kIGFDirName],
        @"/var/jb/var/mobile/Documents",
        [@"/var/mobile/Documents" stringByAppendingPathComponent:kIGFDirName],
        @"/var/mobile/Documents",
        IGFDocumentsDirectory(),
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory()
    ];
    for (NSString *directory in directories) {
        NSString *found = IGFFindVideoInDirectory(directory);
        if (found) return found;
    }
    return nil;
}

static NSHashTable<AVCaptureVideoPreviewLayer *> *s_previewLayers;
static char kIGFPreviewPlayerLayerKey;
static char kIGFPreviewPlayerKey;
static char kIGFPreviewLooperKey;
static char kIGFPreviewPathKey;

static BOOL IGFSessionUsesFrontCamera(AVCaptureSession *session) {
    for (AVCaptureInput *input in session.inputs) {
        if (![input isKindOfClass:AVCaptureDeviceInput.class]) continue;
        if (((AVCaptureDeviceInput *)input).device.position == AVCaptureDevicePositionFront) return YES;
    }
    return NO;
}

static void IGFUpdatePreviewLayer(AVCaptureVideoPreviewLayer *layer) {
    if (!layer) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IGFUpdatePreviewLayer(layer);
        });
        return;
    }

    AVPlayerLayer *playerLayer = objc_getAssociatedObject(layer, &kIGFPreviewPlayerLayerKey);
    BOOL front = layer.session && IGFSessionUsesFrontCamera(layer.session);
    NSString *path = front ? IGFVideoPath() : nil;
    if (!front || path.length == 0) {
        playerLayer.hidden = YES;
        [playerLayer.player pause];
        return;
    }

    NSString *currentPath = objc_getAssociatedObject(layer, &kIGFPreviewPathKey);
    if (playerLayer && ![currentPath isEqualToString:path]) {
        [playerLayer removeFromSuperlayer];
        objc_setAssociatedObject(layer, &kIGFPreviewPlayerLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kIGFPreviewPlayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kIGFPreviewLooperKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kIGFPreviewPathKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        playerLayer = nil;
    }

    if (!playerLayer) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
        AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[item]];
        player.muted = YES;
        AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:item];
        playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        playerLayer.masksToBounds = YES;
        playerLayer.backgroundColor = UIColor.blackColor.CGColor;
        playerLayer.zPosition = 1000;
        playerLayer.transform = IGFMirror() ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity;
        objc_setAssociatedObject(layer, &kIGFPreviewPlayerLayerKey, playerLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kIGFPreviewPlayerKey, player, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kIGFPreviewLooperKey, looper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(layer, &kIGFPreviewPathKey, path, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [layer addSublayer:playerLayer];
        IGFLog([NSString stringWithFormat:@"preview layer attached: %@", path]);
    }

    playerLayer.hidden = NO;
    playerLayer.frame = layer.bounds;
    if (playerLayer.player.rate == 0) [playerLayer.player play];
}

static void IGFRefreshPreviewLayers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (AVCaptureVideoPreviewLayer *layer in s_previewLayers.allObjects) {
            IGFUpdatePreviewLayer(layer);
        }
    });
}

static BOOL IGFSupportedPixelFormat(OSType format) {
    return format == kCVPixelFormatType_32BGRA ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

@interface IGFVideoSource : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, strong) AVAssetTrack *track;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *readerOutput;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) CVPixelBufferPoolRef pool;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, assign) CMVideoDimensions targetSize;
@property (nonatomic, assign) OSType targetFormat;
@property (nonatomic, assign) BOOL mirror;
@property (nonatomic, assign) BOOL preparing;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, assign) BOOL failed;
@end

@implementation IGFVideoSource

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.bluek.frontcam.video", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (void)prepareWithFormat:(CMFormatDescriptionRef)format mirror:(BOOL)mirror {
    if (self.preparing || self.ready) return;
    NSString *path = IGFVideoPath();
    if (path.length == 0) {
        if (!self.failed) IGFLog(@"video file not found");
        self.failed = YES;
        return;
    }
    self.preparing = YES;
    self.mirror = mirror;
    self.targetSize = CMVideoFormatDescriptionGetDimensions(format);
    OSType formatType = CMFormatDescriptionGetMediaSubType(format);
    self.targetFormat = IGFSupportedPixelFormat(formatType) ? formatType : kCVPixelFormatType_32BGRA;
    IGFLog([NSString stringWithFormat:@"loading %@ size=%dx%d format=%c%c%c%c",
            path, self.targetSize.width, self.targetSize.height,
            (char)(self.targetFormat >> 24), (char)(self.targetFormat >> 16),
            (char)(self.targetFormat >> 8), (char)self.targetFormat]);

    dispatch_async(self.queue, ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
            dispatch_async(self.queue, ^{
                NSError *error = nil;
                AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
                NSArray *tracks = status == AVKeyValueStatusLoaded ? [asset tracksWithMediaType:AVMediaTypeVideo] : nil;
                if (tracks.count == 0) {
                    IGFLog([NSString stringWithFormat:@"asset load failed: %@", error.localizedDescription ?: @"no video track"]);
                    self.failed = YES;
                    self.preparing = NO;
                    return;
                }
                self.asset = asset;
                self.track = tracks.firstObject;
                [self createPool];
                if ([self startReader]) {
                    self.ready = YES;
                    IGFLog(@"video source ready");
                } else {
                    self.failed = YES;
                    IGFLog(@"reader start failed");
                }
                self.preparing = NO;
            });
        }];
    });
}

- (void)createPool {
    if (self.pool) return;
    NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @3};
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(self.targetFormat),
        (id)kCVPixelBufferWidthKey: @(self.targetSize.width),
        (id)kCVPixelBufferHeightKey: @(self.targetSize.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolCreate(kCFAllocatorDefault,
                            (__bridge CFDictionaryRef)poolAttributes,
                            (__bridge CFDictionaryRef)bufferAttributes,
                            &_pool);
}

- (BOOL)startReader {
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:&error];
    if (!reader) {
        IGFLog([NSString stringWithFormat:@"asset reader error: %@", error.localizedDescription ?: @"?"]);
        return NO;
    }
    NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(self.targetFormat)};
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:self.track
                                                                       outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) {
        IGFLog([NSString stringWithFormat:@"reader start error: %@", reader.error.localizedDescription ?: @"?"]);
        return NO;
    }
    self.reader = reader;
    self.readerOutput = output;
    return YES;
}

- (CVPixelBufferRef)nextPixelBuffer {
    if (!self.ready || !self.readerOutput) return NULL;
    CMSampleBufferRef sampleBuffer = [self.readerOutput copyNextSampleBuffer];
    if (!sampleBuffer && self.reader.status == AVAssetReaderStatusCompleted) {
        if ([self startReader]) sampleBuffer = [self.readerOutput copyNextSampleBuffer];
    }
    if (!sampleBuffer) return NULL;
    CVPixelBufferRef source = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferRef result = source ? [self renderPixelBuffer:source] : NULL;
    CFRelease(sampleBuffer);
    return result;
}

- (CVPixelBufferRef)renderPixelBuffer:(CVPixelBufferRef)source {
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    if (!image) return NULL;
    if (self.track) image = [image imageByApplyingTransform:self.track.preferredTransform];

    CGRect extent = image.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) return NULL;
    CGFloat scale = MAX(self.targetSize.width / extent.size.width,
                        self.targetSize.height / extent.size.height);
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];

    extent = image.extent;
    CGFloat tx = (self.targetSize.width - extent.size.width) / 2.0 - extent.origin.x;
    CGFloat ty = (self.targetSize.height - extent.size.height) / 2.0 - extent.origin.y;
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    if (self.mirror) {
        CGAffineTransform mirror = CGAffineTransformConcat(
            CGAffineTransformMakeTranslation(self.targetSize.width, 0),
            CGAffineTransformMakeScale(-1, 1));
        image = [image imageByApplyingTransform:mirror];
    }

    CVPixelBufferRef destination = NULL;
    if (self.pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &destination);
    if (!destination) {
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(self.targetFormat),
            (id)kCVPixelBufferWidthKey: @(self.targetSize.width),
            (id)kCVPixelBufferHeightKey: @(self.targetSize.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferCreate(kCFAllocatorDefault, self.targetSize.width, self.targetSize.height,
                            self.targetFormat, (__bridge CFDictionaryRef)attributes, &destination);
    }
    if (!destination) return NULL;

    CGRect bounds = CGRectMake(0, 0, self.targetSize.width, self.targetSize.height);
    [self.ciContext render:image toCVPixelBuffer:destination bounds:bounds colorSpace:self.colorSpace];
    return destination;
}

@end

static CMSampleBufferRef IGFCreateSampleBuffer(CVPixelBufferRef pixelBuffer,
                                               CMSampleBufferRef original) {
    if (!pixelBuffer || !original) return NULL;
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        return NULL;
    }
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration = kCMTimeInvalid;
        timing.presentationTimeStamp = kCMTimeInvalid;
        timing.decodeTimeStamp = kCMTimeInvalid;
    }
    CMSampleBufferRef result = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format,
                                                               &timing, &result);
    CFRelease(format);
    if (status != noErr || !result) return NULL;
    return result;
}

@interface IGFOutputProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id realDelegate;
@property (nonatomic, weak) AVCaptureVideoDataOutput *output;
@property (nonatomic, strong) IGFVideoSource *source;
@end

@implementation IGFOutputProxy

- (BOOL)isFrontCamera {
    AVCaptureConnection *connection = self.output.connections.firstObject;
    AVCaptureInputPort *port = connection.inputPorts.firstObject;
    AVCaptureInput *input = port.input;
    if (![input isKindOfClass:AVCaptureDeviceInput.class]) return NO;
    return ((AVCaptureDeviceInput *)input).device.position == AVCaptureDevicePositionFront;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id delegate = self.realDelegate;
    if (!delegate) return;
    CMSampleBufferRef replacement = NULL;
    if (IGFEnabled() && [self isFrontCamera]) {
        if (!self.source) self.source = [IGFVideoSource new];
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (format && !self.source.ready && !self.source.failed) {
            [self.source prepareWithFormat:format mirror:(IGFMirror() || connection.videoMirrored)];
        }
        CVPixelBufferRef pixelBuffer = [self.source nextPixelBuffer];
        if (pixelBuffer) {
            replacement = IGFCreateSampleBuffer(pixelBuffer, sampleBuffer);
            CVPixelBufferRelease(pixelBuffer);
        }
    }
    if ([delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [delegate captureOutput:output
            didOutputSampleBuffer:(replacement ?: sampleBuffer)
                   fromConnection:connection];
    }
    if (replacement) CFRelease(replacement);
}

- (void)captureOutput:(AVCaptureOutput *)output
didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if ([self.realDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

static char kIGFProxyKey;

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate) {
        IGFOutputProxy *proxy = [IGFOutputProxy new];
        proxy.realDelegate = delegate;
        proxy.output = self;
        objc_setAssociatedObject(self, &kIGFProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IGFLog(@"capture delegate installed");
        %orig(proxy, queue);
    } else {
        objc_setAssociatedObject(self, &kIGFProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(nil, queue);
    }
}

- (id)sampleBufferDelegate {
    IGFOutputProxy *proxy = objc_getAssociatedObject(self, &kIGFProxyKey);
    return proxy.realDelegate ?: %orig;
}

%end

%hook AVCaptureVideoPreviewLayer

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    if (!s_previewLayers) s_previewLayers = [NSHashTable weakObjectsHashTable];
    @synchronized(s_previewLayers) {
        [s_previewLayers addObject:self];
    }
    IGFUpdatePreviewLayer(self);
}

- (void)layoutSublayers {
    %orig;
    IGFUpdatePreviewLayer(self);
}

%end

%hook AVCaptureSession

- (void)addInput:(AVCaptureInput *)input {
    %orig;
    IGFRefreshPreviewLayers();
}

- (void)removeInput:(AVCaptureInput *)input {
    %orig;
    IGFRefreshPreviewLayers();
}

- (void)commitConfiguration {
    %orig;
    IGFRefreshPreviewLayers();
}

%end

%ctor {
    s_previewLayers = [NSHashTable weakObjectsHashTable];
    IGFLog([NSString stringWithFormat:@"loaded bundle=%@ process=%@ video=%@",
            NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
            NSProcessInfo.processInfo.processName ?: @"(nil)",
            IGFVideoPath() ?: @"(missing)"]);
}
