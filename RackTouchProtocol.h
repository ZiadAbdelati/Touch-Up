#ifndef RackTouchProtocol_h
#define RackTouchProtocol_h

#include <stdint.h>

#define kRackTouchVendorID 0x27c0u
#define kRackTouchProductID 0x0859u
#define kRackTouchSocketPath "/var/run/com.rofkek.rack-touch-seizer.sock"
#define kRackTouchPacketMagic 0x52544348u /* RTCH */
#define kRackTouchPacketVersion 1u
#define kRackTouchMaximumReportLength 64u

/* Empirical four-corner calibration for the GeekPi/DeskPi 1280x400 panel. */
#define kRackTouchRawMinX -92.064
#define kRackTouchRawMaxX 16435.664
#define kRackTouchRawMinY -77.908
#define kRackTouchRawMaxY 9905.108
#define kRackTouchLogicalWidth 1280.0
#define kRackTouchLogicalHeight 400.0

#ifdef __OBJC__
#define kRackTouchDisplayName @"RTK FHD"
#define kRackTouchRestoreDisplayName @"T749-fHD720"
#endif

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t reportLength;
    uint32_t locationID;
    uint32_t reportID;
    uint64_t timestamp;
    uint8_t report[kRackTouchMaximumReportLength];
} RackTouchPacket;

#endif
