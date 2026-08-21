//
//  HIDInterpreter.c
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include "HIDInterpreter.h"
#include "TUCTouchInputManager-C.h"
#include "../RackTouchProtocol.h"

#include <mach/mach_port.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <os/log.h>

#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>

#pragma mark - Per-Device State

#define kMaxTouchscreens 4
#define kMaxPassiveSiblings 4
typedef struct {
    IOHIDDeviceRef          device;     // unique identity of this HID interface
    uint32_t                locationID; // shared across interfaces of the same USB device
    CFIndex                 contactCollectionCount; // how many real multitouch contacts this interface reports
    Boolean                 isActive;
    Boolean                 seized;     // whether we hold an exclusive (seized) open on this device

    IOHIDQueueRef           queue;
    Boolean                 areElementRefsSet;
    
    IOHIDElementRef         applicationCollectionElement;
    IOHIDElementRef         scanTimeElement;
    CFMutableArrayRef       touchCollectionElements;
    
    /**
     stores values for the touch collections: cookie -> latest value
     in hybrid mode (especially if order of touches moves) this data has to be set to last state per collection element receiving touches now
     */
    CFMutableDictionaryRef  storedInputValues;
    
    CFMutableArrayRef       contactIdentifiers;
    
    CFIndex                 contactCount;
    CFIndex                 hybridOffset;
    Boolean                 touchscreenUsesHybridMode;
} HIDDeviceState;

static HIDDeviceState gDevices[kMaxTouchscreens];
static int gDeviceCount = 0;

// The WCH controller also publishes a Generic Desktop / Mouse interface. It does
// not contain touch coordinates that Touch Up needs, but WindowServer consumes it
// and generates a second click at the existing cursor position. Keep that one
// interface open exclusively while the real digitizer interface is active.
typedef struct {
    IOHIDDeviceRef device;
    uint32_t locationID;
    Boolean seized;
    uint8_t reportBuffer[64];
    Boolean leftButtonDown;
    Boolean loggedFirstReport;
} HIDPassiveSiblingState;

static HIDPassiveSiblingState gPassiveSiblings[kMaxPassiveSiblings];
static int gPassiveSiblingCount = 0;

#pragma mark - Global variables

static void* gTouchManager;

static CFRunLoopRef gRunLoopRef;

static IOHIDManagerRef gHidManager;

// When true, accepted touch interfaces are opened exclusively (seized) so macOS and other
// apps no longer receive their events — Touch Up becomes the sole handler. Opt-in.
static Boolean gSeizeTouchDevices = false;
static Boolean gRackMouseLeftButtonDown = false;
static Boolean gRackMouseLoggedFirstReport = false;
static Boolean gRackMouseDragging = false;
static Boolean gRackPinching = false;
static Boolean gRackSuppressMouseUntilAllContactsUp = false;
static Boolean gRackDigitizerLoggedFirstReport = false;
static Boolean gRackLoggedLongReportID[256] = { false };
static uint16_t gRackMouseLastX = 0;
static uint16_t gRackMouseLastY = 0;
static CGFloat gRackMouseStartX = 0.0;
static CGFloat gRackMouseStartY = 0.0;
static uint64_t gRackMouseWatchdogGeneration = 0;
static pthread_t gRackBridgeThread;
static Boolean gRackBridgeStarted = false;
static volatile sig_atomic_t gRackBridgeStop = 0;
static int gRackBridgeSocket = -1;
static pthread_mutex_t gRackBridgeSocketLock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gRackTouchLocationID = 0;

uint32_t RackTouchCurrentLocationID(void) {
    return __atomic_load_n(&gRackTouchLocationID, __ATOMIC_RELAXED);
}


#pragma mark - Device State Management


// State is keyed by the IOHIDDeviceRef, not the locationID: a combo digitizer presents
// several HID interfaces that all share one locationID, so the device ref is the only
// reliable per-interface identity.
HIDDeviceState* DeviceStateForRef(IOHIDDeviceRef device) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].device == device) {
            return &gDevices[i];
        }
    }
    return NULL;
}

// Returns the single interface we've accepted as *the* touchscreen for this locationID
// (the one with the most contact collections), or NULL if none is registered yet.
HIDDeviceState* RegisteredDeviceForLocationID(uint32_t locationID) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].locationID == locationID) {
            return &gDevices[i];
        }
    }
    return NULL;
}


HIDDeviceState* AllocateDeviceState(IOHIDDeviceRef device, uint32_t locationID) {
    if (gDeviceCount >= kMaxTouchscreens) {
        fprintf(stderr, "Maximum number of touchscreens (%d) reached.\n", kMaxTouchscreens);
        return NULL;
    }

    HIDDeviceState *state = &gDevices[gDeviceCount];
    memset(state, 0, sizeof(HIDDeviceState));

    state->device = device;
    state->locationID = locationID;
    state->isActive = TRUE;
    state->contactCount = 1;
    state->touchCollectionElements = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->contactIdentifiers = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->storedInputValues = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    
    gDeviceCount++;
    return state;
}


void DeallocateDeviceState(IOHIDDeviceRef device) {
    int index = -1;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].device == device) {
            index = i;
            break;
        }
    }
    if (index < 0) return;
    
    HIDDeviceState *state = &gDevices[index];

    if (state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }

    if (state->queue) {
        IOHIDQueueStop(state->queue);
        CFRelease(state->queue);
    }
    if (state->touchCollectionElements) CFRelease(state->touchCollectionElements);
    if (state->contactIdentifiers) CFRelease(state->contactIdentifiers);
    if (state->storedInputValues) CFRelease(state->storedInputValues);
    
    // move last element into gap to keep array compact
    gDeviceCount--;
    if (index < gDeviceCount) {
        gDevices[index] = gDevices[gDeviceCount];
    }
    memset(&gDevices[gDeviceCount], 0, sizeof(HIDDeviceState));
}


#pragma mark General Debug Utilities




void PrintAddress(UInt8 *ptr, UInt64 length) {
    for (int i=0; i<length; i++) {
        printf("%02x ", ptr[i]);
        if ((i+1)%8 == 0) printf("  ");
        if ((i+1)%32 == 0) printf("\n");
    }
    printf("\n");
}


void PrintInput(IOHIDValueRef inHIDValue) {
    IOHIDElementRef elem = IOHIDValueGetElement(inHIDValue);
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    CFIndex value = IOHIDValueGetIntegerValue(inHIDValue);
    
    IOHIDElementCookie cookie = IOHIDElementGetCookie(elem);
    
    char pageDescr[6]  = "(---)";
    char usageDescr[10] = "(-------)";
    
    if (page == kHIDPage_GenericDesktop) {
        strcpy(pageDescr, "(GD) ");
        if (usage == kHIDUsage_GD_X) {
            strcpy(usageDescr, "(X)      ");
        } else if (usage == kHIDUsage_GD_Y) {
            strcpy(usageDescr, "(Y)      ");
        }
        
    } else if (page == kHIDPage_Digitizer) {
        strcpy(pageDescr, "(Dig)");
        
        if (usage == kHIDUsage_Dig_TipSwitch) {
            strcpy(usageDescr, "(Tip)    ");
        } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
            strcpy(usageDescr, "(Cont ID)");
        } else if (usage == kHIDUsage_Dig_ContactCount) {
            strcpy(usageDescr, "(ContCnt)");
        } else if (usage == kHIDUsage_Dig_TouchValid) {
            strcpy(usageDescr, "(IsValid)");
        } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
            strcpy(usageDescr, "(ScnTime)");
        } else if (usage == kHIDUsage_Dig_Width) {
            strcpy(usageDescr, "(Width)  ");
        } else if (usage == kHIDUsage_Dig_Height) {
            strcpy(usageDescr, "(Height) ");
        } else if (usage == kHIDUsage_Dig_Azimuth) {
            strcpy(usageDescr, "(Azimuth)");
        }
    }
    
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex lMax = IOHIDElementGetLogicalMax(elem);
    
    printf("%u\t| %#02lx %s\t| %#02lx %s\t|%8ld\t(%ld-%ld)\n", cookie, page, pageDescr, usage, usageDescr, value, lMin, lMax);
}





#pragma mark - Storing Values


int64_t StorageKeyForElement(IOHIDElementRef element) {
    return IOHIDElementGetCookie(element);
}



CFIndex ValueOfElement(HIDDeviceState *device, IOHIDElementRef element) {
    
    if (!element) {
        return kCFNotFound;
    }
    
    int64_t hash = StorageKeyForElement(element);
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hash);
    
    if (CFDictionaryContainsKey(device->storedInputValues, key)) {
        CFIndex value;
        CFNumberRef num = CFDictionaryGetValue(device->storedInputValues, key);
        CFNumberGetValue(num, kCFNumberCFIndexType, &value);
        CFRelease(key);
        return value;
        
    }
    CFRelease(key);
    return kCFNotFound;
    
}



void StoreInputValue(HIDDeviceState *device, IOHIDValueRef hidValue) {
    
    CFIndex value = IOHIDValueGetIntegerValue(hidValue);
    IOHIDElementRef elem = IOHIDValueGetElement(hidValue);
    
    CFIndex keyValue = StorageKeyForElement(elem);
    
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyValue);
    
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &value);
    
    CFDictionarySetValue(device->storedInputValues, key, num);
    
    CFRelease(num);
    CFRelease(key);
    
    
    // special case: contact count could be zero in hybrid mode
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    
    if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
        // hybrid mode can only exist if the old value is larger than the number of collections that can be communicated at once
        CFIndex numCollections = CFArrayGetCount(device->touchCollectionElements);
        
        if (device->contactCount > numCollections && value == 0 && device->hybridOffset > 0) {
            device->touchscreenUsesHybridMode = TRUE;
            
        } else {
            device->contactCount = value;
            device->hybridOffset = 0;
        }
    }
}




/**
 We need to inspect the HID tree as a whole once to see which elements are grouped into logical groups of touch data.
 Just pass in any element of the tree, the function will walk up the tree, search for the logical groups and rememeber them in the global variables.
 */
void IdentifyElements(HIDDeviceState *device, IOHIDElementRef anyElement, Boolean printTree) {
    
    IOHIDElementRef applicationCollection = anyElement;
    IOHIDElementType type = kIOHIDElementTypeOutput;
    
    while (type != kIOHIDElementTypeCollection) {
        IOHIDElementRef next = IOHIDElementGetParent(applicationCollection);
        if (next) {
            applicationCollection = next;
            type = IOHIDElementGetType(applicationCollection);
        } else {
            break;
        }
    }
    device->applicationCollectionElement = applicationCollection;
    
    
    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = CFArrayGetCount(children);
    
    if (printTree) {
        printf("# parent (type %u) has %ld children:\n", type, numChildren);
    }
    
    
    for (CFIndex i=0; i<numChildren; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        IOHIDElementType type =  IOHIDElementGetType(element);
        IOHIDElementCollectionType collectionType = IOHIDElementGetCollectionType(element);
        
        if (type == kIOHIDElementTypeCollection && collectionType == kIOHIDElementCollectionTypeLogical) {
            CFArrayAppendValue(device->touchCollectionElements, element);
            
            if (printTree) {
                printf(" > Logical collection %ld\n", i);
                CFArrayRef grandchildren = IOHIDElementGetChildren(element);
                for( CFIndex j=0; j<CFArrayGetCount(grandchildren); j++) {
                    IOHIDElementRef gch = (IOHIDElementRef)CFArrayGetValueAtIndex(grandchildren, j);
                    CFIndex page = IOHIDElementGetUsagePage(gch);
                    CFIndex usage = IOHIDElementGetUsage(gch);
                    CFIndex cookie= IOHIDElementGetCookie(gch);
                    
                    printf("    > %#02lx %#02lx  [%ld]\n", page, usage, cookie);
                }
            }
            
        } // logical collection
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
            if (printTree) {
                printf(" > Contact Count\n");
            }
        }
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_RelativeScanTime) {
            device->scanTimeElement = element;
            if (printTree) {
                printf(" > Scan Time\n");
            }
        }
        
        else {
            if (printTree) {
                printf(" > %#02lx %#02lx\n", page, usage);
            }
        }
    }
}









#pragma mark - Propagate Touch Data to next layer


void PrintTouchCollection(HIDDeviceState *device, IOHIDElementRef collection) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex cookie = IOHIDElementGetCookie(element);
        CFIndex value = ValueOfElement(device, element);
        
        char pageDescr[6]  = "(---)";
        char usageDescr[10] = "(-------)";
        
        if (page == kHIDPage_GenericDesktop) {
            strcpy(pageDescr, "(GD) ");
            if (usage == kHIDUsage_GD_X) {
                strcpy(usageDescr, "(X)      ");
            } else if (usage == kHIDUsage_GD_Y) {
                strcpy(usageDescr, "(Y)      ");
            }
            
        } else if (page == kHIDPage_Digitizer) {
            strcpy(pageDescr, "(Dig)");
            
            if (usage == kHIDUsage_Dig_TipSwitch) {
                strcpy(usageDescr, "(Tip)    ");
            } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
                strcpy(usageDescr, "(Cont ID)");
            } else if (usage == kHIDUsage_Dig_ContactCount) {
                strcpy(usageDescr, "(ContCnt)");
            } else if (usage == kHIDUsage_Dig_TouchValid) {
                strcpy(usageDescr, "(IsValid)");
            } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
                strcpy(usageDescr, "(ScnTime)");
            } else if (usage == kHIDUsage_Dig_Width) {
                strcpy(usageDescr, "(Width)  ");
            } else if (usage == kHIDUsage_Dig_Height) {
                strcpy(usageDescr, "(Height) ");
            } else if (usage == kHIDUsage_Dig_Azimuth) {
                strcpy(usageDescr, "(Azimuth)");
            }
        }
        
        
        
        printf("[%ld]\t%#02lx\t%#02lx %s\t %8ld\n", (long)cookie, page, usage, usageDescr,  value);
    }
    printf("\n");
}


/**
 Dispatches touch data for the given collection, but only if all values needed were received
 */

void DispatchTouchDataForCollection(HIDDeviceState *device, IOHIDElementRef collection) {
    
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    CGFloat x = -1;
    CGFloat y = -1;
    
    CFIndex contactID = 0;
    CFIndex tipSwitch = 0;
    CFIndex isValid = 0;
    
    CFIndex width   = kCFNotFound;
    CFIndex height  = kCFNotFound;
    CFIndex azimuth = kCFNotFound;
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex value = ValueOfElement(device, element);
        
        if (value != kCFNotFound) {
            if (page == kHIDPage_GenericDesktop) {
                if (usage == kHIDUsage_GD_X) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)value;
                    x = ( (curr - min) / (max - min) ) + min;
                }
                
                else if (usage == kHIDUsage_GD_Y) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)value;
                    y = ( (curr - min) / (max - min) ) + min;
                }
            } //kHIDPage_GenericDesktop
            
            else if (page == kHIDPage_Digitizer) {
                if (usage == kHIDUsage_Dig_ContactIdentifier) {
                    contactID = value;
                } else if (usage == kHIDUsage_Dig_TipSwitch) {
                    tipSwitch = value;
                } else if (usage == kHIDUsage_Dig_TouchValid) {
                    isValid = value;
                } else if (usage == kHIDUsage_Dig_Width) {
                    width = value;
                } else if (usage == kHIDUsage_Dig_Height) {
                    height = value;
                } else if (usage == kHIDUsage_Dig_Azimuth) {
                    azimuth = value;
                }
            } // kHIDPage_Digitizer
        }
    }
    TouchInputManagerUpdateTouchPosition(gTouchManager, device->locationID, contactID, x, y, (int)tipSwitch, (int)isValid);
    
    //    if (width != kCFNotFound && height != kCFNotFound && azimuth != kCFNotFound) {
    //        TouchInputManagerUpdateTouchSize(gTouchManager, contactID, (CGFloat)width, (CGFloat)height, (CGFloat)azimuth);
    //    }
    
}



void DispatchTouches(HIDDeviceState *device) {
    
    CFIndex numCollections = CFArrayGetCount(device->touchCollectionElements);
    CFIndex remainingUpdates = device->contactCount - device->hybridOffset;
    
    CFIndex numUpdates = numCollections;
    if (remainingUpdates < numCollections) {
        numUpdates = remainingUpdates;
    }
    
    CFIndex numElementsToPost = CFArrayGetCount(device->touchCollectionElements);
    if (numUpdates < numElementsToPost)
        numElementsToPost = numUpdates;
    
    // update the touch data
    for (CFIndex i=0; i<numElementsToPost; i++) {
        IOHIDElementRef collection = (IOHIDElementRef)CFArrayGetValueAtIndex(device->touchCollectionElements, i);
        DispatchTouchDataForCollection(device, collection);
    }
    
    device->hybridOffset = device->hybridOffset + numUpdates;
    
    if (device->hybridOffset == device->contactCount) {
        device->hybridOffset = 0;
    }
    
    if (device->hybridOffset == 0) {
        TouchInputManagerDidProcessReport(gTouchManager, device->locationID);
    }
    
}



#pragma mark - Exclusive HID Usage (Seizing)

static uint32_t DeviceUInt32Property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    uint32_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &result);
    }
    return result;
}

static Boolean IsRackTouchController(IOHIDDeviceRef device) {
    return DeviceUInt32Property(device, CFSTR(kIOHIDVendorIDKey)) == kRackTouchVendorID &&
           DeviceUInt32Property(device, CFSTR(kIOHIDProductIDKey)) == kRackTouchProductID;
}

static Boolean IsRackTouchMouseInterface(IOHIDDeviceRef device) {
    return IsRackTouchController(device) &&
           DeviceUInt32Property(device, CFSTR(kIOHIDPrimaryUsagePageKey)) == kHIDPage_GenericDesktop &&
           DeviceUInt32Property(device, CFSTR(kIOHIDPrimaryUsageKey)) == kHIDUsage_GD_Mouse;
}

static HIDPassiveSiblingState *PassiveSiblingForRef(IOHIDDeviceRef device) {
    for (int i = 0; i < gPassiveSiblingCount; i++) {
        if (gPassiveSiblings[i].device == device) return &gPassiveSiblings[i];
    }
    return NULL;
}

// This controller never emits reports on its advertised digitizer interface on
// macOS. Its real data arrives as a five-byte absolute mouse report:
//   buttons, X little-endian (0...32767), Y little-endian (0...32767).
// Feed that single contact into Touch Up's normal gesture/click pipeline so all
// existing display binding, rotation and point-and-click preferences still apply.
static CGFloat NormalizeRackCoordinate(uint16_t raw, CGFloat minimum, CGFloat maximum) {
    CGFloat value = ((CGFloat)raw - minimum) / (maximum - minimum);
    if (value < 0.0) value = 0.0;
    if (value > 1.0) value = 1.0;
    return value;
}

static void ScheduleRackMouseReleaseWatchdog(void) {
    uint64_t generation = ++gRackMouseWatchdogGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gRackMouseWatchdogGeneration ||
            !gRackMouseLeftButtonDown) return;

        // The WCH mouse-compatibility endpoint can stop transmitting without
        // a button-up when a second finger changes its device state. Never
        // leave a global Quartz drag latched in that case.
        if (gRackMouseDragging && gTouchManager) {
            TouchInputManagerCancelRackDrag(gTouchManager);
        }
        gRackMouseLeftButtonDown = false;
        gRackMouseDragging = false;
        fprintf(stderr, "Rack touch release watchdog cancelled a stale contact.\n");
    });
}

static void ProcessRackMouseInputReport(uint32_t locationID,
                                        const uint8_t *report,
                                        CFIndex reportLength) {
    // The helper also observes a seven-byte vendor report. Only its synthesized
    // five-byte HID-value packet has an unambiguous buttons/X/Y layout.
    if (!gTouchManager || locationID == 0 || reportLength != 5) return;
    uint8_t buttons = report[0];
    uint16_t rawX = (uint16_t)report[1] |
                    ((uint16_t)report[2] << 8);
    uint16_t rawY = (uint16_t)report[3] |
                    ((uint16_t)report[4] << 8);
    Boolean down = (buttons & 0x01) != 0;
    if (down) ScheduleRackMouseReleaseWatchdog();
    else gRackMouseWatchdogGeneration++;

    // During and after a two-finger gesture, ignore the compatibility mouse
    // stream until the digitizer confirms that every finger has lifted. This
    // prevents its first-contact mouse-up from becoming a stray dashboard tap.
    if (gRackSuppressMouseUntilAllContactsUp) {
        if (!down) gRackMouseLeftButtonDown = false;
        return;
    }

    if (!gRackMouseLoggedFirstReport) {
        fprintf(stderr,
                "Rack touchscreen absolute reports active: len=%ld x=%u y=%u down=%d\n",
                reportLength, rawX, rawY, down);
        gRackMouseLoggedFirstReport = true;
    }

    // Ignore idle hover reports. A stationary contact remains buffered and is
    // emitted as one atomic click on release. Once it moves far enough, convert
    // the same contact into a captured drag until release.
    if (!down && !gRackMouseLeftButtonDown) return;

    gRackMouseLastX = rawX;
    gRackMouseLastY = rawY;

    // Measured at the four physical corners of this panel. The controller does
    // not reach its nominal descriptor extrema, so using 0...max leaves a
    // noticeable inward offset, especially on the short vertical axis.
    CGFloat x = NormalizeRackCoordinate(rawX, kRackTouchRawMinX, kRackTouchRawMaxX);
    CGFloat y = NormalizeRackCoordinate(rawY, kRackTouchRawMinY, kRackTouchRawMaxY);
    if (down && !gRackMouseLeftButtonDown) {
        gRackMouseStartX = x;
        gRackMouseStartY = y;
        gRackMouseDragging = false;
    } else if (down) {
        // Eight screen points filters normal finger jitter without making a
        // Home Assistant slider feel reluctant. This rack display is fixed at
        // 1280x400 logical points; rotation is applied later by the manager.
        CGFloat dx = (x - gRackMouseStartX) * kRackTouchLogicalWidth;
        CGFloat dy = (y - gRackMouseStartY) * kRackTouchLogicalHeight;
        static const CGFloat kRackDragThresholdSquared = 8.0 * 8.0;
        if (!gRackMouseDragging && dx * dx + dy * dy >= kRackDragThresholdSquared) {
            fprintf(stderr, "Rack drag began normalized=(%.4f, %.4f)\n",
                    gRackMouseStartX, gRackMouseStartY);
            TouchInputManagerBeginRackDrag(gTouchManager, locationID,
                                           gRackMouseStartX, gRackMouseStartY);
            gRackMouseDragging = true;
        }
        if (gRackMouseDragging) {
            TouchInputManagerUpdateRackDrag(gTouchManager, locationID, x, y);
        }
    } else if (gRackMouseLeftButtonDown) {
        if (gRackMouseDragging) {
            fprintf(stderr, "Rack drag ended normalized=(%.4f, %.4f)\n", x, y);
            TouchInputManagerEndRackDrag(gTouchManager, locationID, x, y);
        } else {
            fprintf(stderr, "Rack tap raw: x=%u y=%u normalized=(%.4f, %.4f)\n",
                    gRackMouseLastX, gRackMouseLastY, x, y);
            TouchInputManagerPerformRackTap(gTouchManager, locationID, x, y);
        }
        gRackMouseDragging = false;
    }
    gRackMouseLeftButtonDown = down;
}

typedef struct {
    uint8_t contactID;
    CGFloat x;
    CGFloat y;
} RackDigitizerContact;

// The WCH digitizer descriptor exposes report 0x0d as ten five-byte finger
// records followed by scan-time and contact-count fields:
//   TipSwitch:1, pad:3, ContactID:4, X:16 LE, Y:16 LE
// The callback may include the report-ID byte in the buffer (54 bytes) or pass
// it separately (53 bytes), so accept both representations.
static Boolean ProcessRackDigitizerInputReport(uint32_t locationID,
                                                uint32_t reportID,
                                                const uint8_t *report,
                                                CFIndex reportLength) {
    if (!gTouchManager || locationID == 0) return false;

    // Length identifies this interface reliably even on IOHID callback
    // variants that report ID zero. The mouse/vendor interfaces on this
    // controller are at most seven bytes.
    if (reportLength < 53) {
        return false;
    }

    // IOHID passes the report ID separately, but some macOS/controller
    // combinations also retain it as byte zero. MaxInputReportSize (54)
    // includes that byte even when the callback buffer begins with contact 0,
    // so length alone cannot determine the offset.
    CFIndex base = (reportLength >= 54 && report[0] == 0x0d) ? 1 : 0;
    if (reportLength - base < 53) return false;

    RackDigitizerContact contacts[10];
    CFIndex activeCount = 0;
    for (CFIndex slot = 0; slot < 10; slot++) {
        CFIndex offset = base + slot * 5;
        uint8_t flags = report[offset];
        if ((flags & 0x01) == 0) continue;

        uint16_t rawX = (uint16_t)report[offset + 1] |
                        ((uint16_t)report[offset + 2] << 8);
        uint16_t rawY = (uint16_t)report[offset + 3] |
                        ((uint16_t)report[offset + 4] << 8);
        contacts[activeCount].contactID = (flags >> 4) & 0x0f;
        contacts[activeCount].x = NormalizeRackCoordinate(rawX, 0.0, 16383.0);
        contacts[activeCount].y = NormalizeRackCoordinate(rawY, 0.0, 9599.0);
        activeCount++;
    }

    // Keep the same two contacts in a stable order if firmware changes slots.
    for (CFIndex i = 0; i < activeCount; i++) {
        for (CFIndex j = i + 1; j < activeCount; j++) {
            if (contacts[j].contactID < contacts[i].contactID) {
                RackDigitizerContact temporary = contacts[i];
                contacts[i] = contacts[j];
                contacts[j] = temporary;
            }
        }
    }

    if (!gRackDigitizerLoggedFirstReport) {
        fprintf(stderr,
                "Rack multitouch digitizer reports active: id=0x%02x len=%ld contacts=%ld\n",
                reportID, reportLength, activeCount);
        os_log(OS_LOG_DEFAULT,
               "Rack multitouch digitizer reports active: id=0x%{public}x len=%{public}ld base=%{public}ld contacts=%{public}ld",
               reportID, reportLength, base, activeCount);
        gRackDigitizerLoggedFirstReport = true;
    }

    if (activeCount >= 2) {
        gRackSuppressMouseUntilAllContactsUp = true;
        if (!gRackPinching) {
            if (gRackMouseDragging) {
                TouchInputManagerCancelRackDrag(gTouchManager);
            }
            gRackMouseDragging = false;
            gRackMouseLeftButtonDown = false;
            TouchInputManagerBeginRackPinch(gTouchManager, locationID,
                                            contacts[0].x, contacts[0].y,
                                            contacts[1].x, contacts[1].y);
            gRackPinching = true;
            fprintf(stderr, "Rack pinch began: contacts %u and %u\n",
                    contacts[0].contactID, contacts[1].contactID);
            os_log(OS_LOG_DEFAULT, "Rack pinch began: contacts %{public}u and %{public}u",
                   contacts[0].contactID, contacts[1].contactID);
        } else {
            TouchInputManagerUpdateRackPinch(gTouchManager, locationID,
                                             contacts[0].x, contacts[0].y,
                                             contacts[1].x, contacts[1].y);
        }
    } else if (gRackPinching) {
        TouchInputManagerEndRackPinch(gTouchManager);
        gRackPinching = false;
        fprintf(stderr, "Rack pinch ended.\n");
        os_log(OS_LOG_DEFAULT, "Rack pinch ended");
    }

    if (activeCount == 0) {
        gRackSuppressMouseUntilAllContactsUp = false;
    }
    return true;
}

static void ProcessRackInputReport(uint32_t locationID,
                                   uint32_t reportID,
                                   const uint8_t *report,
                                   CFIndex reportLength) {
    if (reportLength > 5 && reportID < 256 && !gRackLoggedLongReportID[reportID]) {
        os_log(OS_LOG_DEFAULT,
               "Rack raw report: id=0x%{public}x len=%{public}ld first=%{public}02x %{public}02x %{public}02x %{public}02x",
               reportID, reportLength,
               reportLength > 0 ? report[0] : 0,
               reportLength > 1 ? report[1] : 0,
               reportLength > 2 ? report[2] : 0,
               reportLength > 3 ? report[3] : 0);
        gRackLoggedLongReportID[reportID] = true;
    }
    if (ProcessRackDigitizerInputReport(locationID, reportID, report, reportLength)) return;
    ProcessRackMouseInputReport(locationID, report, reportLength);
}

static void Handle_RackMouseInputReport(void *context,
                                        IOReturn result,
                                        void *sender,
                                        IOHIDReportType type,
                                        uint32_t reportID,
                                        uint8_t *report,
                                        CFIndex reportLength) {
    (void)result;
    (void)type;
    IOHIDDeviceRef device = (IOHIDDeviceRef)(context ? context : sender);
    HIDPassiveSiblingState *state = PassiveSiblingForRef(device);
    if (state) ProcessRackInputReport(state->locationID, reportID, report, reportLength);
}

static void SetRackBridgeSocket(int socketFD) {
    pthread_mutex_lock(&gRackBridgeSocketLock);
    gRackBridgeSocket = socketFD;
    pthread_mutex_unlock(&gRackBridgeSocketLock);
}

static ssize_t ReceiveRackPacket(int socketFD, RackTouchPacket *packet) {
    size_t offset = 0;
    while (offset < sizeof(*packet)) {
        ssize_t received = recv(socketFD,
                                ((uint8_t *)packet) + offset,
                                sizeof(*packet) - offset,
                                0);
        if (received == 0) return 0;
        if (received < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t)received;
    }
    return (ssize_t)offset;
}

// Runs on Touch Up's HID run loop. A bridge loss must never leave a synthetic
// mouse button held or the cursor hidden, and the next connection must begin
// from an idle contact state rather than consuming a stale release.
static void ResetRackMouseGestureState(void) {
    if (gRackMouseDragging && gTouchManager) {
        TouchInputManagerCancelRackDrag(gTouchManager);
    }
    if (gRackPinching && gTouchManager) {
        TouchInputManagerCancelRackPinch(gTouchManager);
    }
    gRackMouseDragging = false;
    gRackPinching = false;
    gRackSuppressMouseUntilAllContactsUp = false;
    gRackMouseLeftButtonDown = false;
}

static void ScheduleRackMouseGestureReset(void) {
    if (!gRunLoopRef) return;
    CFRunLoopPerformBlock(gRunLoopRef, kCFRunLoopCommonModes, ^{
        ResetRackMouseGestureState();
    });
    CFRunLoopWakeUp(gRunLoopRef);
}

static void *RackBridgeReceiveLoop(void *unused) {
    (void)unused;
    while (!gRackBridgeStop) {
        int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
        if (socketFD < 0) {
            usleep(250000);
            continue;
        }

        struct sockaddr_un address;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, kRackTouchSocketPath, sizeof(address.sun_path));
        if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
            close(socketFD);
            usleep(250000);
            continue;
        }

        SetRackBridgeSocket(socketFD);
        fprintf(stderr, "Connected to privileged rack-touch report bridge.\n");

        while (!gRackBridgeStop) {
            RackTouchPacket packet;
            ssize_t received = ReceiveRackPacket(socketFD, &packet);
            if (received != sizeof(packet)) break;
            if (packet.magic != kRackTouchPacketMagic ||
                packet.version != kRackTouchPacketVersion ||
                packet.reportLength > kRackTouchMaximumReportLength ||
                packet.locationID == 0) continue;

            __atomic_store_n(&gRackTouchLocationID, packet.locationID, __ATOMIC_RELAXED);

            RackTouchPacket capturedPacket = packet;
            CFRunLoopPerformBlock(gRunLoopRef, kCFRunLoopCommonModes, ^{
                ProcessRackInputReport(capturedPacket.locationID,
                                       capturedPacket.reportID,
                                       capturedPacket.report,
                                       capturedPacket.reportLength);
            });
            CFRunLoopWakeUp(gRunLoopRef);
        }

        pthread_mutex_lock(&gRackBridgeSocketLock);
        if (gRackBridgeSocket == socketFD) gRackBridgeSocket = -1;
        pthread_mutex_unlock(&gRackBridgeSocketLock);
        close(socketFD);
        ScheduleRackMouseGestureReset();
    }
    return NULL;
}

static void StartRackBridge(void) {
    if (gRackBridgeStarted) return;
    gRackBridgeStop = 0;
    if (pthread_create(&gRackBridgeThread, NULL, RackBridgeReceiveLoop, NULL) == 0) {
        gRackBridgeStarted = true;
    }
}

static void StopRackBridge(void) {
    if (!gRackBridgeStarted) return;
    gRackBridgeStop = 1;
    pthread_mutex_lock(&gRackBridgeSocketLock);
    if (gRackBridgeSocket >= 0) shutdown(gRackBridgeSocket, SHUT_RDWR);
    pthread_mutex_unlock(&gRackBridgeSocketLock);
    pthread_join(gRackBridgeThread, NULL);
    gRackBridgeStarted = false;
    ResetRackMouseGestureState();
}

static void ApplyPassiveSiblingSeizeState(HIDPassiveSiblingState *state) {
    if (gSeizeTouchDevices && !state->seized) {
        IOReturn result = IOHIDDeviceOpen(state->device, kIOHIDOptionsTypeSeizeDevice);
        if (result == kIOReturnSuccess) {
            state->seized = true;
            fprintf(stderr, "Exclusive rack-touch mouse capture enabled for 0x%08x\n",
                    state->locationID);
        } else {
            fprintf(stderr,
                    "Failed to seize rack-touch mouse interface 0x%08x (IOReturn 0x%08x)\n",
                    state->locationID, result);
        }
    } else if (!gSeizeTouchDevices && state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }
}

static void RegisterPassiveSibling(IOHIDDeviceRef device, uint32_t locationID) {
    if (PassiveSiblingForRef(device)) return;
    if (gPassiveSiblingCount >= kMaxPassiveSiblings) {
        fprintf(stderr, "Maximum number of passive touchscreen interfaces reached.\n");
        return;
    }

    HIDPassiveSiblingState *state = &gPassiveSiblings[gPassiveSiblingCount++];
    memset(state, 0, sizeof(*state));
    state->device = (IOHIDDeviceRef)CFRetain(device);
    state->locationID = locationID;
    IOHIDDeviceRegisterInputReportCallback(state->device,
                                           state->reportBuffer,
                                           sizeof(state->reportBuffer),
                                           Handle_RackMouseInputReport,
                                           (void *)state->device);
    ApplyPassiveSiblingSeizeState(state);
}

static Boolean UnregisterPassiveSibling(IOHIDDeviceRef device) {
    for (int i = 0; i < gPassiveSiblingCount; i++) {
        HIDPassiveSiblingState *state = &gPassiveSiblings[i];
        if (state->device != device) continue;

        if (state->seized) {
            IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        }
        CFRelease(state->device);

        gPassiveSiblingCount--;
        if (i < gPassiveSiblingCount) {
            gPassiveSiblings[i] = gPassiveSiblings[gPassiveSiblingCount];
        }
        memset(&gPassiveSiblings[gPassiveSiblingCount], 0, sizeof(HIDPassiveSiblingState));
        return true;
    }
    return false;
}

/*!
 Brings a device's exclusive-open state in line with gSeizeTouchDevices.
 Seizing routes the device's events to us alone (macOS stops receiving them); releasing returns it to shared use.
 Idempotent — only opens/closes when the state actually changes.
 */
static void ApplySeizeState(HIDDeviceState *state) {
    // Never capture JetKVM or any other digitizer. Only the rack touchscreen's
    // WCH controller needs native event suppression.
    if (!IsRackTouchController(state->device)) {
        if (state->seized) {
            IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
            state->seized = false;
        }
        return;
    }

    if (gSeizeTouchDevices && !state->seized) {
        IOReturn r = IOHIDDeviceOpen(state->device, kIOHIDOptionsTypeSeizeDevice);
        if (r == kIOReturnSuccess) {
            state->seized = true;
            fprintf(stderr, "Exclusive touch capture enabled for 0x%08x\n", state->locationID);
        } else {
            fprintf(stderr, "Failed to seize device 0x%08x (IOReturn 0x%08x)\n", state->locationID, r);
        }
    } else if (!gSeizeTouchDevices && state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }
}


/*!
 Opt-in exclusive access. When enabled, every accepted touch interface (current andfuture) is seized so macOS no longer receives its events.
 Applies immediately to all currently-connected touch devices; pen interfaces we never registered stay shared, so the pen keeps working through macOS.
 */
void SetTouchDevicesSeized(bool seize) {
    gSeizeTouchDevices = seize;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive) {
            ApplySeizeState(&gDevices[i]);
        }
    }
    for (int i = 0; i < gPassiveSiblingCount; i++) {
        ApplyPassiveSiblingSeizeState(&gPassiveSiblings[i]);
    }
}



#pragma mark - Callbacks

/*!
 @param context void * pointer to your data, often a pointer to an object.
 @param result Completion result of desired operation.
 @param inSender Interface instance sending the completion routine.
 */

static void Handle_QueueValueAvailable(
    void * _Nullable        context,
    IOReturn                result,
    void * _Nullable        inSender
) {
    HIDDeviceState *device = DeviceStateForRef((IOHIDDeviceRef)context);
    if (!device) return;

    do {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout((IOHIDQueueRef) inSender, 0.);
        if (!valueRef)  {
            // finished processing 1 report
            DispatchTouches(device);
            break;
        }
        // process the HID value reference
        StoreInputValue(device, valueRef);
        
        // Don't forget to release our HID value reference
        CFRelease(valueRef);
    } while (1) ;
}


static void Handle_InputValueCallback (
    void *          inContext,      // context from IOHIDManagerRegisterInputValueCallback
    IOReturn        inResult,       // completion result for the input value operation
    void *          inSender,       // the IOHIDManagerRef
    IOHIDValueRef   inIOHIDValueRef // the new element value
) {
    HIDDeviceState *device = DeviceStateForRef((IOHIDDeviceRef)inContext);
    if (!device) return;

    if(!device->areElementRefsSet) {
        IOHIDElementRef e = IOHIDValueGetElement(inIOHIDValueRef);
        IdentifyElements(device, e, TRUE);
        device->areElementRefsSet = TRUE;
    }
    
    //PrintInput(inIOHIDValueRef);
    IOHIDElementRef elem = IOHIDValueGetElement(inIOHIDValueRef);
    
    Boolean added = IOHIDQueueContainsElement(device->queue, elem);
    if(!added) {
        IOHIDQueueAddElement(device->queue, elem);
        StoreInputValue(device, inIOHIDValueRef);
    }
    
}








/**
 Counts the logical collections that contain a ContactIdentifier, i.e. the number of
 simultaneous touch contacts this HID interface can report. This is how we tell the real
 multitouch surface (several contacts) apart from a sibling interface that only exposes a
 single-pointer or pen path (one or zero contacts) under the same locationID.
 */
static CFIndex CountContactCollections(IOHIDDeviceRef dev) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    if (!elements) return 0;

    CFIndex contactCollections = 0;
    CFIndex count = CFArrayGetCount(elements);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IOHIDElementGetType(el) != kIOHIDElementTypeCollection) continue;
        if (IOHIDElementGetCollectionType(el) != kIOHIDElementCollectionTypeLogical) continue;

        CFArrayRef kids = IOHIDElementGetChildren(el);
        for (CFIndex j = 0; j < CFArrayGetCount(kids); j++) {
            IOHIDElementRef kid = (IOHIDElementRef)CFArrayGetValueAtIndex(kids, j);
            if (IOHIDElementGetUsagePage(kid) == kHIDPage_Digitizer &&
                IOHIDElementGetUsage(kid) == kHIDUsage_Dig_ContactIdentifier) {
                contactCollections++;
                break;
            }
        }
    }
    CFRelease(elements);
    return contactCollections;
}



// Allocates device state and wires up the queue + input callbacks for an interface we've
// decided to treat as the active touchscreen. The callback context is the device ref so
// callbacks resolve to the right per-interface state even when locationIDs collide.
static HIDDeviceState* RegisterTouchDevice(IOHIDDeviceRef dev, uint32_t locationID, CFIndex contactCount) {
    HIDDeviceState *device = AllocateDeviceState(dev, locationID);
    if (!device) return NULL;
    device->contactCollectionCount = contactCount;

    void *context = (void *)dev;

    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, dev, 1000, kNilOptions);
    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, context);
    IOHIDQueueStart(queue);
    device->queue = queue;
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);

    IOHIDDeviceRegisterInputValueCallback(dev, Handle_InputValueCallback, context);

    ApplySeizeState(device);
    return device;
}


// this will be called when the HID Manager matches a new (hot plugged) HID device
static void Handle_DeviceMatchingCallback(
    void *          inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
    IOReturn        inResult,        // the result of the matching operation
    void *          inSender,        // the IOHIDManagerRef for the new device
    IOHIDDeviceRef  inIOHIDDeviceRef // the new HID device
) {
    printf("%s(context: %p, result: %d, sender: %p, device: %p).\n",
           __PRETTY_FUNCTION__, inContext, inResult, inSender, (void*) inIOHIDDeviceRef);

    // read the location ID for this device
    CFNumberRef locationRef = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    uint32_t locationID = 0;
    if (locationRef) {
        CFNumberGetValue(locationRef, kCFNumberSInt32Type, &locationID);
    }

    printf("Touchscreen connected with locationID: 0x%08x\n", locationID);

    // This exact WCH controller's mouse-compatible sibling is the source of the
    // native cursor-relative click. Capture it, but never feed it into Touch Up's
    // coordinate parser. Matching vendor/product/usage keeps every other mouse,
    // including JetKVM, completely outside this path.
    if (IsRackTouchMouseInterface(inIOHIDDeviceRef)) {
        printf("Rack touchscreen mouse sibling connected at 0x%08x\n", locationID);
        RegisterPassiveSibling(inIOHIDDeviceRef, locationID);
        return;
    }

    // A combo digitizer exposes several interfaces under one locationID. Keep only the one
    // that actually carries multitouch: the interface with the most contact collections.
    CFIndex contactCount = CountContactCollections(inIOHIDDeviceRef);
    HIDDeviceState *existing = RegisteredDeviceForLocationID(locationID);

    if (existing == NULL) {
        if (RegisterTouchDevice(inIOHIDDeviceRef, locationID, contactCount)) {
            TouchInputManagerDidConnectTouchscreen(gTouchManager, locationID);
        }
    } else if (contactCount > existing->contactCollectionCount) {
        // A better interface for an already-connected screen arrived (connect order is not
        // deterministic). Swap to it without bothering the upper layer — the locationID,
        // which is all the upper layer keys on, stays connected throughout.
        printf("Switching primary interface for 0x%08x: %ld -> %ld contact collections\n",
               locationID, existing->contactCollectionCount, contactCount);
        IOHIDDeviceRef oldDev = existing->device;
        IOHIDDeviceRegisterInputValueCallback(oldDev, NULL, NULL);
        DeallocateDeviceState(oldDev);
        RegisterTouchDevice(inIOHIDDeviceRef, locationID, contactCount);
    } else {
        printf("Ignoring secondary interface for 0x%08x (%ld <= %ld contact collections)\n",
               locationID, contactCount, existing->contactCollectionCount);
    }
}   // Handle_DeviceMatchingCallback



// this will be called when a HID device is removed (unplugged)
static void Handle_RemovalCallback(
                                   void *         inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
                                   IOReturn       inResult,        // the result of the removing operation
                                   void *         inSender,        // the IOHIDManagerRef for the device being removed
                                   IOHIDDeviceRef inIOHIDDeviceRef // the removed HID device
) {
    printf("%s(context: %p, result: %d, sender: %p, device: %p).\n",
           __PRETTY_FUNCTION__, inContext, inResult, inSender, (void*) inIOHIDDeviceRef);

    if (UnregisterPassiveSibling(inIOHIDDeviceRef)) {
        printf("Rack touchscreen mouse sibling disconnected.\n");
        return;
    }
    
    // Only the interface we actually registered as the touchscreen has state. Secondary
    // interfaces we ignored at match time have none, so their removal is a no-op and must
    // not tell the upper layer the screen went away while the primary is still present.
    HIDDeviceState *device = DeviceStateForRef(inIOHIDDeviceRef);
    if (!device) return;

    uint32_t locationID = device->locationID;
    printf("Touchscreen disconnected with locationID: 0x%08x\n", locationID);

    DeallocateDeviceState(inIOHIDDeviceRef);

    TouchInputManagerDidDisconnectTouchscreen(gTouchManager, locationID);
}   // Handle_RemovalCallback



#pragma mark - Start / Stop


// function to create matching dictionary
static CFMutableDictionaryRef CreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage) {
    // create a dictionary to add usage page/usages to
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
                                                              kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result) {
        if (inUsagePage) {
            // Add key for device type to refine the matching dictionary.
            CFNumberRef pageCFNumberRef = CFNumberCreate(
                                                         kCFAllocatorDefault, kCFNumberIntType, &inUsagePage);
            if (pageCFNumberRef) {
                CFDictionarySetValue(result,
                                     CFSTR(kIOHIDDeviceUsagePageKey), pageCFNumberRef);
                CFRelease(pageCFNumberRef);
                
                // note: the usage is only valid if the usage page is also defined
                if (inUsage) {
                    CFNumberRef usageCFNumberRef = CFNumberCreate(
                                                                  kCFAllocatorDefault, kCFNumberIntType, &inUsage);
                    if (usageCFNumberRef) {
                        CFDictionarySetValue(result,
                                             CFSTR(kIOHIDDeviceUsageKey), usageCFNumberRef);
                        CFRelease(usageCFNumberRef);
                    } else {
                        fprintf(stderr, "%s: CFNumberCreate(usage) failed.", __PRETTY_FUNCTION__);
                    }
                }
            } else {
                fprintf(stderr, "%s: CFNumberCreate(usage page) failed.", __PRETTY_FUNCTION__);
            }
        }
    } else {
        fprintf(stderr, "%s: CFDictionaryCreateMutable failed.", __PRETTY_FUNCTION__);
    }
    return result;
}   // CreateDeviceMatchingDictionary





void OpenHIDManager(void *delegate) {
    gTouchManager = delegate;

    // Raw HID listening is controlled by macOS Input Monitoring. Asking up front
    // makes the required privacy entry visible instead of silently receiving a
    // non-privileged open that cannot actually suppress WindowServer's events.
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (access == kIOHIDAccessTypeUnknown) {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    }
    fprintf(stderr, "Touch Up Input Monitoring access: %s\n",
            access == kIOHIDAccessTypeGranted ? "granted" :
            access == kIOHIDAccessTypeDenied ? "denied" : "not yet decided");
    
    
    gHidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    
    if (CFGetTypeID(gHidManager) != IOHIDManagerGetTypeID()) {
        printf("OH CRAP THIS IS NOT AN HID MANAGER");
    }
    
    
    //    CFMutableDictionaryRef keyboard =
    //    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Pen);
    //    CFMutableDictionaryRef keypad =
    //    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Touch);
    
    CFMutableDictionaryRef matchesList[] = {
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen),
    };
    
    
    
    CFArrayRef matches = CFArrayCreate(kCFAllocatorDefault,
                                       (const void **)matchesList, 1, NULL);
    IOHIDManagerSetDeviceMatchingMultiple(gHidManager, matches);
    CFRelease(matches);
    
    IOHIDManagerRegisterDeviceMatchingCallback(gHidManager, Handle_DeviceMatchingCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHidManager, Handle_RemovalCallback, NULL);
    
    //    IOHIDManagerRegisterInputReportWithTimeStampCallback(gHidManager, Handle_ReportCallback, NULL);
    
    
    gRunLoopRef = CFRunLoopGetMain();
    StartRackBridge();
    
    IOHIDManagerScheduleWithRunLoop(gHidManager, gRunLoopRef,
                                    kCFRunLoopCommonModes);
    
    IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeNone);
}



void CloseHIDManager(void) {
    StopRackBridge();
    // clean up all active device states (DeallocateDeviceState releases any seize)
    while (gDeviceCount > 0) {
        DeallocateDeviceState(gDevices[0].device);
    }
    while (gPassiveSiblingCount > 0) {
        UnregisterPassiveSibling(gPassiveSiblings[0].device);
    }

    IOHIDManagerUnscheduleFromRunLoop(gHidManager, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDManagerClose(gHidManager, kIOHIDOptionsTypeNone);
}
