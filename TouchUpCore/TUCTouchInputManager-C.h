//
//  TUCTouchInputManager-C.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include <CoreGraphics/CoreGraphics.h>

#ifndef TUCTouchInputManager_C_h
#define TUCTouchInputManager_C_h

void TouchInputManagerUpdateTouchPosition(void *self, uint32_t locationID, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid);

void TouchInputManagerUpdateTouchSize(void *self, uint32_t locationID, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth);

// called after a full report (no partials in hybrid modes) was handled
void TouchInputManagerDidProcessReport(void *self, uint32_t locationID);

void TouchInputManagerDidConnectTouchscreen(void *self, uint32_t locationID);

void TouchInputManagerDidDisconnectTouchscreen(void *self, uint32_t locationID);

// Atomically clicks a rack-screen point, hiding the cursor during the click and
// restoring it to its previous (typically JetKVM) position immediately after.
void TouchInputManagerPerformRackTap(void *self, uint32_t locationID, CGFloat x, CGFloat y);

// Atomically right-clicks a rack-screen point for a stationary long press.
// The physical button-up is consumed by the HID recognizer, so it cannot turn
// into a follow-up primary click that dismisses the resulting context menu.
void TouchInputManagerPerformRackSecondaryTap(void *self, uint32_t locationID,
                                               CGFloat x, CGFloat y);

// Synthesizes a rack-screen drag while keeping the cursor hidden. The cursor is
// restored to its previous (typically JetKVM) position when the drag ends.
void TouchInputManagerBeginRackDrag(void *self, uint32_t locationID, CGFloat x, CGFloat y);
void TouchInputManagerUpdateRackDrag(void *self, uint32_t locationID, CGFloat x, CGFloat y);
void TouchInputManagerEndRackDrag(void *self, uint32_t locationID, CGFloat x, CGFloat y);
void TouchInputManagerCancelRackDrag(void *self);

// Posts a two-contact magnify gesture at the midpoint of the rack touches
// without moving the visible system cursor away from JetKVM.
void TouchInputManagerBeginRackPinch(void *self, uint32_t locationID,
                                    CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2);
void TouchInputManagerUpdateRackPinch(void *self, uint32_t locationID,
                                     CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2);
void TouchInputManagerEndRackPinch(void *self);
void TouchInputManagerCancelRackPinch(void *self);

#endif /* TUCTouchInputManager_C_h */
