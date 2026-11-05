// A virtual monitor macOS treats as real: `vdisplay right|left|above|below [width height]`. Plugged while it runs, unplugged when killed.
#import <AppKit/AppKit.h>
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, retain) dispatch_queue_t queue;
@property (nonatomic, retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned)w height:(unsigned)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, retain) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)d;
- (BOOL)applySettings:(id)s;
@property (readonly) unsigned int displayID;
@end
int main(int argc, char **argv) { @autoreleasepool {
    const char *side = argc > 1 ? argv[1] : "right";
    unsigned w = argc > 3 ? atoi(argv[2]) : 1920, h = argc > 3 ? atoi(argv[3]) : 1080;
    CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
    d.queue = dispatch_get_main_queue(); d.name = @"Seam Test"; d.maxPixelsWide = w; d.maxPixelsHigh = h; d.sizeInMillimeters = CGSizeMake(530, 300);
    d.vendorID = 0x5345; d.productID = 0x414d; d.serialNum = 1; d.terminationHandler = ^(id a, id b) {};
    CGVirtualDisplay *v = [[CGVirtualDisplay alloc] initWithDescriptor:d];
    CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new]; s.hiDPI = 0;
    s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
    if (![v applySettings:s]) return 1;
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    CGRect main = CGDisplayBounds(CGMainDisplayID());
    int x = 0, y = 0;
    if (!strcmp(side, "right")) x = main.size.width;
    if (!strcmp(side, "left")) x = -(int)w;
    if (!strcmp(side, "above")) y = -(int)h;
    if (!strcmp(side, "below")) y = main.size.height;
    CGDisplayConfigRef c; CGBeginDisplayConfiguration(&c);
    CGConfigureDisplayOrigin(c, v.displayID, x, y);
    CGCompleteDisplayConfiguration(c, kCGConfigureForSession);
    printf("%u\n", v.displayID); fflush(stdout);
    [[NSRunLoop mainRunLoop] run];
} }
