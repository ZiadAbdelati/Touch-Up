#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include "../RackTouchProtocol.h"
#include <errno.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static IOHIDManagerRef gManager;
static int gServerSocket = -1;
static int gClientSocket = -1;
static pthread_mutex_t gClientLock = PTHREAD_MUTEX_INITIALIZER;
static Boolean gLoggedFirstValueReport = false;
static unsigned gRawReportLogCount = 0;
static unsigned gDigitizerValueLogCount = 0;
static uid_t gConsoleUID = (uid_t)-1;
static gid_t gConsoleGID = (gid_t)-1;
static uint32_t gRackLocationID = 0;

static void WaitForConsoleUser(void) {
    struct stat consoleInfo;
    for (;;) {
        if (stat("/dev/console", &consoleInfo) == 0 && consoleInfo.st_uid != 0) {
            struct passwd *account = getpwuid(consoleInfo.st_uid);
            gConsoleUID = consoleInfo.st_uid;
            gConsoleGID = account ? account->pw_gid : consoleInfo.st_gid;
            return;
        }
        sleep(1);
    }
}

static uint32_t DeviceUInt32Property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    uint32_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &result);
    }
    return result;
}

static Boolean IsRackInterface(IOHIDDeviceRef device, uint32_t usagePage, uint32_t usage) {
    return device &&
           DeviceUInt32Property(device, CFSTR(kIOHIDVendorIDKey)) == kRackTouchVendorID &&
           DeviceUInt32Property(device, CFSTR(kIOHIDProductIDKey)) == kRackTouchProductID &&
           DeviceUInt32Property(device, CFSTR(kIOHIDPrimaryUsagePageKey)) == usagePage &&
           DeviceUInt32Property(device, CFSTR(kIOHIDPrimaryUsageKey)) == usage;
}

static Boolean IsRackMouseInterface(IOHIDDeviceRef device) {
    return IsRackInterface(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse);
}

static Boolean IsRackDigitizerInterface(IOHIDDeviceRef device) {
    return IsRackInterface(device, kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen);
}

static void ReplaceClient(int client) {
    pthread_mutex_lock(&gClientLock);
    if (gClientSocket >= 0) close(gClientSocket);
    gClientSocket = client;
    pthread_mutex_unlock(&gClientLock);
}

static void *AcceptClients(void *unused) {
    (void)unused;
    for (;;) {
        int client = accept(gServerSocket, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }

        uid_t uid = (uid_t)-1;
        gid_t gid = (gid_t)-1;
        if (getpeereid(client, &uid, &gid) != 0 || uid != gConsoleUID) {
            close(client);
            continue;
        }
        int noSigPipe = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        ReplaceClient(client);
        fprintf(stderr, "Touch Up report bridge connected (uid %u).\n", uid);
    }
    return NULL;
}

static int StartReportServer(void) {
    WaitForConsoleUser();
    unlink(kRackTouchSocketPath);
    gServerSocket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (gServerSocket < 0) return -1;

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, kRackTouchSocketPath, sizeof(address.sun_path));
    if (bind(gServerSocket, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        chown(kRackTouchSocketPath, gConsoleUID, gConsoleGID) != 0 ||
        chmod(kRackTouchSocketPath, 0600) != 0 ||
        listen(gServerSocket, 2) != 0) {
        close(gServerSocket);
        gServerSocket = -1;
        unlink(kRackTouchSocketPath);
        return -1;
    }

    pthread_t thread;
    if (pthread_create(&thread, NULL, AcceptClients, NULL) != 0) return -1;
    pthread_detach(thread);
    return 0;
}

static void ForwardReport(const uint8_t *report, CFIndex reportLength,
                          uint32_t reportID, uint64_t timestamp) {
    if (reportLength <= 0) return;

    RackTouchPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.magic = kRackTouchPacketMagic;
    packet.version = kRackTouchPacketVersion;
    packet.reportLength = (uint16_t)(reportLength > kRackTouchMaximumReportLength
                                    ? kRackTouchMaximumReportLength : reportLength);
    packet.locationID = gRackLocationID;
    packet.reportID = reportID;
    packet.timestamp = timestamp;
    memcpy(packet.report, report, packet.reportLength);

    pthread_mutex_lock(&gClientLock);
    if (gClientSocket >= 0) {
        size_t offset = 0;
        while (offset < sizeof(packet)) {
            ssize_t sent = send(gClientSocket,
                                ((const uint8_t *)&packet) + offset,
                                sizeof(packet) - offset,
                                MSG_DONTWAIT);
            if (sent <= 0) break;
            offset += (size_t)sent;
        }
        if (offset != sizeof(packet)) {
            close(gClientSocket);
            gClientSocket = -1;
        }
    }
    pthread_mutex_unlock(&gClientLock);
}

static void ForwardInputReport(void *context, IOReturn result, void *sender,
                               IOHIDReportType type, uint32_t reportID,
                               uint8_t *report, CFIndex reportLength,
                               uint64_t timestamp) {
    (void)context;
    (void)result;
    (void)sender;
    (void)type;
    if (gRawReportLogCount < 24) {
        fprintf(stderr,
                "Rack raw HID report: id=0x%02x len=%ld first=%02x %02x %02x %02x result=0x%08x.\n",
                reportID, reportLength,
                reportLength > 0 ? report[0] : 0,
                reportLength > 1 ? report[1] : 0,
                reportLength > 2 ? report[2] : 0,
                reportLength > 3 ? report[3] : 0,
                result);
        gRawReportLogCount++;
    }
    // The mouse interface's descriptor is report 0x07 followed by buttons,
    // absolute X/Y, and wheel. Forward one compact packet per physical HID
    // report instead of rebuilding reports from separately delivered element
    // values. That preserves every up/down edge when a tap is followed quickly
    // by another contact; run-loop coalescing used to lose the intermediate up.
    if (reportID == 0x07) {
        CFIndex payloadOffset = reportLength == 7 && report[0] == 0x07 ? 1 : 0;
        if (reportLength - payloadOffset >= 5) {
            uint8_t compactReport[5] = {
                report[payloadOffset],
                report[payloadOffset + 1],
                report[payloadOffset + 2],
                report[payloadOffset + 3],
                report[payloadOffset + 4],
            };
            if (!gLoggedFirstValueReport) {
                uint16_t x = (uint16_t)compactReport[1] |
                             ((uint16_t)compactReport[2] << 8);
                uint16_t y = (uint16_t)compactReport[3] |
                             ((uint16_t)compactReport[4] << 8);
                fprintf(stderr,
                        "Rack touchscreen physical reports active: x=%u y=%u buttons=0x%02x.\n",
                        x, y, compactReport[0]);
                gLoggedFirstValueReport = true;
            }
            ForwardReport(compactReport, sizeof(compactReport), 0, timestamp);
            return;
        }
    }

    // The WCH digitizer advertises a 54-byte report (ID 0x0d) containing all
    // ten contact collections. Keep the report ID and timestamp intact so the
    // user process can decode complete contact/frame boundaries.
    if (reportID == 0x0d && reportLength == 54) {
        ForwardReport(report, reportLength, reportID, timestamp);
        return;
    }
    ForwardReport(report, reportLength, reportID, timestamp);
}

static void ForwardInputValue(void *context, IOReturn result, void *sender,
                              IOHIDValueRef value) {
    (void)context;
    (void)result;
    (void)sender;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    IOHIDDeviceRef device = IOHIDElementGetDevice(element);
    if (IsRackDigitizerInterface(device)) {
        if (gDigitizerValueLogCount < 80) {
            fprintf(stderr,
                    "Rack digitizer HID value: cookie=%u page=0x%04x usage=0x%04x report=0x%02x value=%ld min=%ld max=%ld.\n",
                    (unsigned)IOHIDElementGetCookie(element),
                    IOHIDElementGetUsagePage(element),
                    IOHIDElementGetUsage(element),
                    IOHIDElementGetReportID(element),
                    IOHIDValueGetIntegerValue(value),
                    IOHIDElementGetLogicalMin(element),
                    IOHIDElementGetLogicalMax(element));
            gDigitizerValueLogCount++;
        }
        return;
    }
    // Mouse reports are forwarded atomically by ForwardInputReport. Element
    // callbacks are intentionally ignored here so they cannot duplicate or
    // coalesce button transitions.
}

static void StopRunLoop(int signalNumber) {
    (void)signalNumber;
    if (CFRunLoopGetMain()) CFRunLoopStop(CFRunLoopGetMain());
}

static IOReturn SetRackDigitizerModeElement(IOHIDDeviceRef device,
                                            CFIndex *readBackValue) {
    IOReturn result = kIOReturnNotFound;
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL,
                                                           kIOHIDOptionsTypeNone);
    if (!elements) return result;

    for (CFIndex index = 0; index < CFArrayGetCount(elements); index++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, index);
        if (IOHIDElementGetType(element) != kIOHIDElementTypeFeature ||
            IOHIDElementGetUsagePage(element) != kHIDPage_Digitizer ||
            IOHIDElementGetUsage(element) != 0x52) continue;

        IOHIDValueRef modeValue = IOHIDValueCreateWithIntegerValue(
            kCFAllocatorDefault, element, mach_absolute_time(), 0x02);
        if (!modeValue) {
            result = kIOReturnNoMemory;
            break;
        }
        result = IOHIDDeviceSetValue(device, element, modeValue);
        CFRelease(modeValue);

        IOHIDValueRef readValue = NULL;
        IOReturn readResult = IOHIDDeviceGetValueWithOptions(
            device, element, &readValue, kIOHIDDeviceGetValueWithUpdate);
        if (readResult == kIOReturnSuccess && readValue) {
            *readBackValue = IOHIDValueGetIntegerValue(readValue);
        }
        fprintf(stderr,
                "Rack Device Mode element: report=0x%02x cookie=%u set=0x%08x read=0x%08x value=%ld.\n",
                IOHIDElementGetReportID(element),
                (unsigned)IOHIDElementGetCookie(element),
                result, readResult, *readBackValue);
        break;
    }
    CFRelease(elements);
    return result;
}

static void DeviceMatched(void *context, IOReturn result, void *sender,
                          IOHIDDeviceRef device) {
    (void)context;
    (void)sender;
    CFNumberRef locationValue = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDLocationIDKey));
    uint32_t locationID = 0;
    if (locationValue) {
        CFNumberGetValue(locationValue, kCFNumberSInt32Type, &locationID);
    }
    const char *interfaceName = IsRackDigitizerInterface(device) ? "digitizer" :
                                 IsRackMouseInterface(device) ? "mouse" : "unknown";
    fprintf(stderr,
            "Captured rack touchscreen %s interface at 0x%08x (match result 0x%08x).\n",
            interfaceName, locationID, result);
    if (locationID != 0) gRackLocationID = locationID;

    if (IsRackDigitizerInterface(device)) {
        // This controller follows the Windows HID multitouch convention: it
        // powers up in mouse/single-touch mode until the host writes Digitizer
        // Device Mode (usage 0x52). Its descriptor places Device Mode and
        // Device Identifier in feature report 0x21. Preserve the identifier
        // while selecting touchscreen multitouch mode 0x02, matching Linux's
        // hid-multitouch driver.
        CFIndex readBackValue = -1;
        IOReturn setResult = SetRackDigitizerModeElement(device, &readBackValue);
        if (setResult != kIOReturnSuccess) {
            // Descriptor-driven setting is preferred. Keep a standards-based
            // raw fallback for older IOHID implementations.
            uint8_t modeReport[3] = { 0x21, 0x02, 0x00 };
            setResult = IOHIDDeviceSetReport(device,
                                              kIOHIDReportTypeFeature,
                                              0x21,
                                              modeReport,
                                              sizeof(modeReport));
            fprintf(stderr,
                    "Rack Device Mode raw fallback: set=0x%08x.\n",
                    setResult);
        }
    }
}

static void DeviceRemoved(void *context, IOReturn result, void *sender,
                          IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;
    (void)device;
    fprintf(stderr, "Rack touchscreen interface disconnected; waiting for reconnect.\n");
}

static void AddNumber(CFMutableDictionaryRef dictionary, CFStringRef key, uint32_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
}

int main(void) {
    signal(SIGTERM, StopRunLoop);
    signal(SIGINT, StopRunLoop);

    if (StartReportServer() != 0) {
        fprintf(stderr, "Unable to create Touch Up report bridge socket.\n");
        return 1;
    }

    CFMutableDictionaryRef mouseMatch = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    AddNumber(mouseMatch, CFSTR(kIOHIDVendorIDKey), kRackTouchVendorID);
    AddNumber(mouseMatch, CFSTR(kIOHIDProductIDKey), kRackTouchProductID);
    AddNumber(mouseMatch, CFSTR(kIOHIDDeviceUsagePageKey), kHIDPage_GenericDesktop);
    AddNumber(mouseMatch, CFSTR(kIOHIDDeviceUsageKey), kHIDUsage_GD_Mouse);

    gManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    // The daemon owns only the mouse-compatible sibling. Touch Up opens the
    // digitizer directly, so including both interfaces here creates an
    // all-or-nothing exclusive-open race after either process restarts.
    IOHIDManagerSetDeviceMatching(gManager, mouseMatch);
    CFRelease(mouseMatch);

    IOHIDManagerRegisterDeviceMatchingCallback(gManager, DeviceMatched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gManager, DeviceRemoved, NULL);
    IOHIDManagerRegisterInputReportWithTimeStampCallback(gManager, ForwardInputReport, NULL);
    IOHIDManagerRegisterInputValueCallback(gManager, ForwardInputValue, NULL);
    IOHIDManagerScheduleWithRunLoop(gManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    IOReturn result = IOHIDManagerOpen(gManager, kIOHIDOptionsTypeSeizeDevice);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "Unable to open rack touchscreen mouse exclusively (0x%08x).\n", result);
        IOHIDManagerUnscheduleFromRunLoop(gManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(gManager);
        return 1;
    }

    fprintf(stderr, "Rack touchscreen mouse suppression active.\n");
    CFRunLoopRun();

    IOHIDManagerUnscheduleFromRunLoop(gManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDManagerClose(gManager, kIOHIDOptionsTypeSeizeDevice);
    CFRelease(gManager);
    ReplaceClient(-1);
    if (gServerSocket >= 0) close(gServerSocket);
    unlink(kRackTouchSocketPath);
    return 0;
}
