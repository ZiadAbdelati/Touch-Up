#import <Cocoa/Cocoa.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "../RackTouchProtocol.h"

static const CGPoint kTargets[] = {
    {16, 16}, {320, 16}, {640, 16}, {960, 16}, {1264, 16},
    {1264, 200}, {960, 200}, {640, 200}, {320, 200}, {16, 200},
    {16, 384}, {320, 384}, {640, 384}, {960, 384}, {1264, 384},
};
static const NSUInteger kTargetCount = sizeof(kTargets) / sizeof(kTargets[0]);

@class RackCalibrationController;
static RackCalibrationController *gController;
static pthread_t gReaderThread;

static ssize_t ReadExact(int fd, void *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, (uint8_t *)buffer + offset, length - offset);
        if (count == 0) return 0;
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t)count;
    }
    return (ssize_t)offset;
}

static int CompareUInt16(const void *left, const void *right) {
    uint16_t a = *(const uint16_t *)left;
    uint16_t b = *(const uint16_t *)right;
    return (a > b) - (a < b);
}

@interface RackCalibrationView : NSView
@property NSUInteger targetIndex;
@end

@implementation RackCalibrationView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithWhite:0.04 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    CGPoint target = kTargets[self.targetIndex];
    CGFloat y = NSHeight(self.bounds) - target.y;
    [[NSColor systemRedColor] setStroke];
    NSBezierPath *crosshair = [NSBezierPath bezierPath];
    crosshair.lineWidth = 3.0;
    [crosshair moveToPoint:NSMakePoint(target.x - 14, y)];
    [crosshair lineToPoint:NSMakePoint(target.x + 14, y)];
    [crosshair moveToPoint:NSMakePoint(target.x, y - 14)];
    [crosshair lineToPoint:NSMakePoint(target.x, y + 14)];
    [crosshair stroke];

    NSString *message = [NSString stringWithFormat:
        @"Calibration %lu/%lu — press and briefly hold the red crosshair",
        (unsigned long)(self.targetIndex + 1), (unsigned long)kTargetCount];
    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
    };
    NSSize size = [message sizeWithAttributes:attributes];
    [message drawAtPoint:NSMakePoint((NSWidth(self.bounds) - size.width) * 0.5,
                                     (NSHeight(self.bounds) - size.height) * 0.5)
          withAttributes:attributes];
}
@end

@interface RackCalibrationController : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property RackCalibrationView *view;
@property NSUInteger targetIndex;
@property NSMutableArray<NSString *> *rows;
- (void)recordRawX:(uint16_t)rawX rawY:(uint16_t)rawY;
@end

@implementation RackCalibrationController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSScreen *rackScreen = nil;
    for (NSScreen *screen in NSScreen.screens) {
        if ([screen.localizedName isEqualToString:kRackTouchDisplayName]) {
            rackScreen = screen;
            break;
        }
    }
    if (!rackScreen) {
        fprintf(stderr, "Could not find display named RTK FHD.\n");
        [NSApp terminate:nil];
        return;
    }

    self.rows = [NSMutableArray arrayWithObject:@"target_x,target_y,raw_x,raw_y"];
    self.view = [[RackCalibrationView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 400)];
    self.window = [[NSWindow alloc] initWithContentRect:rackScreen.frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.contentView = self.view;
    self.window.backgroundColor = NSColor.blackColor;
    self.window.level = NSScreenSaverWindowLevel;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;
    [self.window orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)recordRawX:(uint16_t)rawX rawY:(uint16_t)rawY {
    if (self.targetIndex >= kTargetCount) return;
    CGPoint target = kTargets[self.targetIndex];
    NSString *row = [NSString stringWithFormat:@"%.0f,%.0f,%u,%u",
                     target.x, target.y, rawX, rawY];
    [self.rows addObject:row];
    printf("%s\n", row.UTF8String);
    fflush(stdout);

    self.targetIndex += 1;
    if (self.targetIndex == kTargetCount) {
        NSString *csv = [[self.rows componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        NSError *error = nil;
        [csv writeToFile:@"/tmp/rack-touch-calibration.csv"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&error];
        if (error) fprintf(stderr, "Could not write calibration CSV: %s\n", error.description.UTF8String);
        [self.window orderOut:nil];
        [NSApp terminate:nil];
        return;
    }
    self.view.targetIndex = self.targetIndex;
    [self.view setNeedsDisplay:YES];
}
@end

static void *ReadReports(void *unused) {
    (void)unused;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, kRackTouchSocketPath, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        perror("connect rack-touch socket");
        close(fd);
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        return NULL;
    }

    uint16_t rawX[64], rawY[64];
    size_t sampleCount = 0;
    BOOL wasDown = NO;
    RackTouchPacket packet;
    while (ReadExact(fd, &packet, sizeof(packet)) == sizeof(packet)) {
        if (packet.magic != kRackTouchPacketMagic ||
            packet.version != kRackTouchPacketVersion) continue;

        BOOL down;
        uint16_t x;
        uint16_t y;
        if (packet.reportLength == 5) {
            down = (packet.report[0] & 0x01) != 0;
            x = (uint16_t)packet.report[1] | ((uint16_t)packet.report[2] << 8);
            y = (uint16_t)packet.report[3] | ((uint16_t)packet.report[4] << 8);
        } else if (packet.reportLength == 7 && packet.report[0] == 0x07) {
            // The controller's native report includes its report-ID byte.
            down = (packet.report[1] & 0x01) != 0;
            x = (uint16_t)packet.report[2] | ((uint16_t)packet.report[3] << 8);
            y = (uint16_t)packet.report[4] | ((uint16_t)packet.report[5] << 8);
        } else {
            continue;
        }
        if (down) {
            if (!wasDown) sampleCount = 0;
            if (sampleCount < 64) {
                rawX[sampleCount] = x;
                rawY[sampleCount] = y;
                sampleCount++;
            } else {
                memmove(rawX, rawX + 1, 63 * sizeof(uint16_t));
                memmove(rawY, rawY + 1, 63 * sizeof(uint16_t));
                rawX[63] = x;
                rawY[63] = y;
            }
        } else if (wasDown && sampleCount > 0) {
            qsort(rawX, sampleCount, sizeof(uint16_t), CompareUInt16);
            qsort(rawY, sampleCount, sizeof(uint16_t), CompareUInt16);
            uint16_t medianX = rawX[sampleCount / 2];
            uint16_t medianY = rawY[sampleCount / 2];
            dispatch_async(dispatch_get_main_queue(), ^{
                [gController recordRawX:medianX rawY:medianY];
            });
            sampleCount = 0;
        }
        wasDown = down;
    }
    close(fd);
    return NULL;
}

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyAccessory;
        gController = [RackCalibrationController new];
        application.delegate = gController;
        pthread_create(&gReaderThread, NULL, ReadReports, NULL);
        pthread_detach(gReaderThread);
        [application run];
    }
    return 0;
}
