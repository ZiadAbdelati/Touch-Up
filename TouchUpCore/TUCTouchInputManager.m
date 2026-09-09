//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"
#import "../RackTouchProtocol.h"
#import <dlfcn.h>

static const CGFloat kRackTopEdgeStartZone = 48.0;
static const CGFloat kRackTopEdgeRevealDistance = 24.0;
static const CGFloat kRackTopEdgeApproachInset = 12.0;

static TUCScreen *RackPreferredRestoreScreen(TUCScreen *rackScreen);
static void RackForceCursorRestore(TUCTouchInputManager *manager);

@interface TUCTouchInputManager ()

@property NSMutableDictionary<NSNumber *, NSNumber *> *frameIDsByLocationID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold; //
@property (strong) NSDate *cursorTouchStationarySinceDate;

@property CGFloat pinchDistance;

@property TUCCursorGesture identifiedMultitouchGesture;

@property BOOL rackSyntheticDragActive;
@property CGPoint rackSyntheticDragRestorePoint;
@property CGPoint rackSyntheticDragStartPoint;
@property CGPoint rackSyntheticDragLastPoint;
@property pid_t rackSyntheticDragTargetPID;
@property int64_t rackSyntheticDragEventNumber;
@property BOOL rackSyntheticDragConstrained;
@property BOOL rackSyntheticDragReleaseAtStart;
@property CGRect rackSyntheticDragConstraintRect;

@property BOOL rackSyntheticScrollActive;
@property CGPoint rackSyntheticScrollRestorePoint;
@property CGPoint rackSyntheticScrollLastPoint;
@property CGPoint rackSyntheticScrollStartPoint;
@property BOOL rackTopEdgeRevealCandidate;
@property BOOL rackChromeRevealActive;

@property BOOL rackSyntheticPinchActive;
@property CGPoint rackSyntheticPinchRestorePoint;
@property CGPoint rackSyntheticPinchLastPoint;
@property CGFloat rackSyntheticPinchLastDistance;
@property pid_t rackSyntheticPinchTargetPID;

@property BOOL rackCursorHideRequested;
@property NSUInteger rackCursorHideBalance;
@property NSUInteger rackCursorRestoreGeneration;

@end


@implementation TUCTouchInputManager

#pragma mark   Start & Stop

- (void)start {
    // Recover from an interrupted synthetic gesture before opening HID again.
    // This rack installation intentionally keeps the remote-console pointer on
    // JetKVM whenever Touch Up starts or restarts.
    CGAssociateMouseAndMouseCursorPosition(true);
    TUCScreen *rackScreen = nil;
    for (TUCScreen *screen in [TUCScreen allScreens]) {
        if ([screen.name isEqualToString:kRackTouchDisplayName]) {
            rackScreen = screen;
            break;
        }
    }
    TUCScreen *restoreScreen = RackPreferredRestoreScreen(rackScreen);
    if (restoreScreen) {
        CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(restoreScreen.frame),
                                              CGRectGetMidY(restoreScreen.frame)));
    }
    CGDisplayShowCursor(kCGNullDirectDisplay);

    // The privileged helper owns the mouse-compatible HID path. Touch Up
    // exclusively opens only the accepted digitizer interface; physical mouse
    // reports arrive later through the helper's private socket.
    SetTouchDevicesSeized(true);

    __weak id weakSelf = self;
    
    // needs to run on main anyway
//    [NSThread detachNewThreadWithBlock:^{
//        [NSThread setThreadPriority:1];
    OpenHIDManager((__bridge void *)(weakSelf));
//    }];
    
}

- (void)stop {
    [self cancelRackSyntheticDrag];
    [self cancelRackSyntheticPinch];
    RackForceCursorRestore(self);
    SetTouchDevicesSeized(false);
    CloseHIDManager();
}

- (void)setTouchscreensSeized:(BOOL)seized {
    SetTouchDevicesSeized(seized);
}


- (void)didConnectTouchscreenWithLocationID:(uint32_t)locationID {
    self.frameIDsByLocationID[@(locationID)] = @0;
    [self.delegate touchscreenDidConnectWithLocationID:locationID];
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    NSLog(@"Touch Up mapping: 0x%08x -> %@ (%@), frame %@",
          locationID, screen.name, screen.uuid, NSStringFromRect(screen.frame));
}

- (void)didDisconnectTouchscreenWithLocationID:(uint32_t)locationID {
    [self.frameIDsByLocationID removeObjectForKey:@(locationID)];
    [self.delegate touchscreenDidDisconnectWithLocationID:locationID];
}



#pragma mark - Reacting to HID Events

- (NSInteger)currentFrameIDForLocationID:(uint32_t)locationID {
    return self.frameIDsByLocationID[@(locationID)].integerValue;
}

- (void)didProcessReportForLocationID:(uint32_t)locationID {
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    NSInteger currentFrameID = [self currentFrameIDForLocationID:locationID];

    for (TUCTouch *touch in self.touchSet) {
        if (touch.locationID != locationID) continue;

        if (touch.lastUpdated + self.errorResistance < currentFrameID) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }

    self.frameIDsByLocationID[@(locationID)] = @(currentFrameID + 1);

    [self processTouchesForCursorInput];

}


- (void)stopCurrentGesture {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];

    self.identifiedMultitouchGesture = _TUCCursorGestureNone;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }
    
    CGPoint point = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint locationID:locationID];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    
    if (isNewTouch && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        self.cursorTouch = touch;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchStationarySinceDate = nil;
    }
    
    [touch setLocation: point];
    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not
        CGFloat digitizerRelDistance = sqrt(pow(touch.location.x - touch.previousLocation.x, 2) + pow(touch.location.y - touch.previousLocation.y, 2));
        CGFloat screenSize = [self touchscreenForLocationID:locationID].nativePhysicalSize.width;
        //TODO: - Make customizable in settings?
        BOOL isStationary = (digitizerRelDistance * screenSize) < 0.1;
//        BOOL isStationary = CGPointEqualToPoint(touch.location, touch.previousLocation);
        
        if (touch.uuid == self.cursorTouch.uuid) {
            if (!isStationary) {
                self.cursorTouchQualifiedForTap = NO;
                self.cursorTouchStationarySinceDate = nil;
                
            } else if (touch.phase !=  NSTouchPhaseStationary) {
                self.cursorTouchStationarySinceDate = [NSDate date];
            }
        }
        
        [touch setPhase:isStationary ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management



- (void)processTouchesForCursorInput {
    
    if(!self.cursorTouch || !self.postMouseEvents) {
        return;
    }
    
    TUCTouch *cursorTouch = self.cursorTouch;
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    NSTouchPhase phase = cursorTouch.phase;
    
    
    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
        }
        
        [self checkForSecondaryClick];
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            if (self.cursorTouchDidHold) {
                [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
            } else if (!self.cursorTouchQualifiedForTap) {
                [self performMouseEventForGesture:TUCCursorGestureDrag];
            }
        }
        
        [self stopCurrentGesture];
        
        if (self.cursorTouchQualifiedForTap) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        } else {
            if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
                [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            }
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
        return;
    }
    
    if ([self checkForSecondaryClick]) {
        return;
    }
    
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        // check if we need to initiate two finger drag, pinch, ...
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            
            TUCTouch *otherTouch = touches[1];
            if (otherTouch.uuid == cursorTouch.uuid) {
                otherTouch = touches[0];
            }
            
            self.gestureAdditionalTouch = otherTouch;
            
            if (self.gestureAdditionalTouch.isActive) {
                CGPoint trajectoryA = [cursorTouch trajectorySign];
                CGPoint trajectoryB = [otherTouch trajectorySign];
                
                
                if (   !CGPointEqualToPoint(trajectoryA, CGPointZero)
                    && !CGPointEqualToPoint(trajectoryB, CGPointZero)) {
                    
                    if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
                        self.identifiedMultitouchGesture = TUCCursorGesturePinch;
                    }
                    //                    else {
                    //                        self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
                    //                    }
                }
                
            } else {
                // secondary click
                [self removeTouch:self.gestureAdditionalTouch now:YES];
                self.gestureAdditionalTouch = nil;
                [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            }
        }
        
        // other finger lifted, gesture ended
        if (!self.gestureAdditionalTouch.isActive) {
            [self stopCurrentGesture];
        }
        
        
        if(self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
            [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            return;
        }
        
    }
    
    
    if (self.cursorTouchDidHold) {
        [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
    } else {
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


- (BOOL)checkForSecondaryClick {
    //    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
    //        return NO;
    //    }
    
    NSSet<TUCTouch *> *touchesInProximity = [self touchesInProximityTo:self.cursorTouch.location maxDistance:60 locationID:self.cursorTouch.locationID];
    if (touchesInProximity.count >= 2 && self.identifiedMultitouchGesture == _TUCCursorGestureNone) {
        
        // TUCCursorGestureTwoFingerTap
        NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseEnded];
        NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseCancelled];
        
        NSPredicate *p3 = [NSPredicate predicateWithFormat:@"contactID != %d", self.cursorTouch.contactID];
        
        NSPredicate *p4 = [NSCompoundPredicate orPredicateWithSubpredicates:@[p1, p2]];
        NSPredicate *p5 = [NSCompoundPredicate andPredicateWithSubpredicates:@[p3, p4]];
        
        NSSet<TUCTouch *> *endedTouches = [touchesInProximity filteredSetUsingPredicate:p5];
        
        if (endedTouches.count == 1) {
            for (TUCTouch* touchToRemove in endedTouches) {
                [self removeTouch:touchToRemove now:YES];
            }
            
            [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            return YES;
        }
    }
    return NO;
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
    CGPoint location2ndFinger = [self convertScreenPointRelativeToAbsolute:self.gestureAdditionalTouch.location locationID:touch.locationID];
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreenForLocationID:touch.locationID] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded:
            [utils moveCursorTo:screenLocation];
            if ([self isLocationOutsideFrontmostWindow:screenLocation locationID:touch.locationID]) {
                [utils performClickAt:screenLocation];
            }
            
            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag:
            [utils dragCursorTo:screenLocation phase:touch.phase];
            break;
            
        case TUCCursorActionClick:
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            [utils performSecondaryClickAt: screenLocation];
            break;
            
        case TUCCursorActionScroll: {
            CGPoint prevLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation locationID:touch.locationID];
            CGPoint translation = CGPointMake(screenLocation.x - prevLocation.x,
                                              screenLocation.y - prevLocation.y);
            [utils scroll:translation phase:touch.phase];
            
            break; }
            
        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
                         relativeP1:self.cursorTouch.location relP2:self.gestureAdditionalTouch.location];
            
            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break;
    }
}


- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    
    if (self.delegate != nil) {
        return [self.delegate actionForGesture:gesture];
    }
    
    switch(gesture) {
        case TUCCursorGestureTouchDown:         return TUCCursorActionMoveClickIfNeeded;
        case TUCCursorGestureTap:               return TUCCursorActionClick;
        case TUCCursorGestureLongPress:         return TUCCursorActionClick;
        case TUCCursorGestureDrag:              return TUCCursorActionScroll;
        case TUCCursorGestureHoldAndDrag:       return TUCCursorActionDrag;
        case TUCCursorGestureTapSecondFinger:   return TUCCursorActionSecondaryClick;
        case TUCCursorGestureTwoFingerDrag:     return TUCCursorActionDrag;
            
        case TUCCursorGesturePinch:             return TUCCursorActionMagnify;
        case _TUCCursorGestureNone:             return TUCCursorActionNone;
    }
}


#pragma mark - Touch Set

/**
 The `touchSet` can contain touches whose phase is ended or cancelled. activeTouches. filteres those out
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseEnded];
    NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseCancelled];
    
    NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[p1, p2]];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}


/**
 maxDistance in mm
 */
- (NSSet<TUCTouch *> *)touchesInProximityTo:(CGPoint)point maxDistance:(CGFloat)mmDistance locationID:(uint32_t)locationID {
    
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    CGFloat screenDistance = mmDistance * [screen pixelsPerMM];
    CGPoint distance = CGPointMake(screenDistance / screen.frame.size.width,
                                   screenDistance / screen.frame.size.height);
    
    NSPredicate * predicate = [NSPredicate predicateWithBlock: ^BOOL(TUCTouch *t, NSDictionary *bind) {
        if (t.locationID != locationID) return NO;

        CGFloat dx = [t location].x - point.x;
        CGFloat dy = [t location].y - point.y;

        return sqrt( pow(dx, 2) + pow(dy, 2) ) < distance.x;
    }];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}


/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
    //    if (touch.uuid == self.touchUsedForCursor.uuid) {
    //        [self processTouchesForCursorInput];
    //        self.touchUsedForCursor = nil;
    //    }
    
    if (instantDeletion) {
        [[self touchSet] removeObject:touch];
        [[self delegate] touchesDidChange];
        return;
    }
    
    __weak id weakSelf = self;
    NSUUID *uuid = touch.uuid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        for(TUCTouch *touch in [weakSelf touchSet]) {
            if (touch.uuid == uuid && [[weakSelf touchSet] containsObject:touch]) {
                [[weakSelf touchSet] removeObject:touch];
                [[weakSelf delegate] touchesDidChange];
                return;
            }
        }
    });
}


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouches];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"contactID == %d AND locationID == %u", contactID, locationID];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID locationID:locationID includingPastTouches:NO];
    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID locationID:locationID];
        [self.touchSet addObject:touch];
        *isNew = YES;
    }
    return touch;
}





#pragma mark - Screen Characteristics

/**
 the relative hardware points are always in the direction the digitizer is built in.
 If the display is rotated, we need to rotate these points
 */
- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];

    CGFloat rotation = screen.rotation;

    CGFloat extra = [[self delegate] digitizerRotationForLocationID:locationID];

    rotation += extra;
    rotation = fmod(rotation, 360);
    if (rotation < 0) {
        rotation += 360;
    }

    // Rotate the glass-relative point into the screen's content orientation.
    CGPoint rotated;
    if (rotation == 180) {
        rotated = CGPointMake(1 - devicePoint.x, 1 - devicePoint.y);
    } else if (rotation == 90) {
        rotated = CGPointMake(1 - devicePoint.y, devicePoint.x);
    } else if (rotation == 270) {
        rotated = CGPointMake(devicePoint.y, 1 - devicePoint.x);
    } else {
        rotated = devicePoint;
    }

    // The GeekPi rack panel is driven as its own 1280x400 display and the raw
    // four-corner calibration already spans the complete touch glass. Its EDID
    // also advertises conventional video modes; using the largest advertised
    // mode here makes the generic aspect-fit code incorrectly treat the top and
    // bottom of the ultrawide glass as letterbox bars. That collapses roughly
    // the outer fifths of Y to the screen edges and makes top-row controls
    // require a touch well below them. Keep rotation, but map this controller's
    // calibrated glass directly across the full rack display.
    if (locationID != 0 && locationID == RackTouchCurrentLocationID()) {
        return rotated;
    }

    // Then account for any genuine letterboxing when another touchscreen's
    // content doesn't fill its panel. A no-op when the aspect ratios match.
    return [screen convertGlassPointToContentPoint:rotated];
}



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID {
    return [[self touchscreenForLocationID:locationID] convertPointRelativeToAbsolute:relativePoint];
}



- (TUCScreen *)touchscreenForLocationID:(uint32_t)locationID {
    if (locationID != 0 && locationID == RackTouchCurrentLocationID()) {
        for (TUCScreen *screen in [TUCScreen allScreens]) {
            if ([screen.name isEqualToString:kRackTouchDisplayName]) {
                return screen;
            }
        }
    }

    if (self.delegate != nil) {
        return [self.delegate touchscreenForLocationID:locationID];
    }
    
    return [[TUCScreen allScreens] firstObject];
}



- (BOOL)isPointInMenuBar:(CGPoint)point locationID:(uint32_t)locationID {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];
    
    CGRect screenFrame = [self touchscreenForLocationID:locationID].frame;
    CGRect menuBarFrame = CGRectMake(screenFrame.origin.x,
                                     screenFrame.origin.y * -1,
                                     screenFrame.size.width,
                                     menuBarHeight);
    
    if (CGRectContainsPoint(menuBarFrame, point)) {
        return YES;
    }
    return NO;
}


- (BOOL)isSystemChromeOwner:(pid_t)pid name:(NSString *)ownerName {
    static NSSet<NSString *> *chromeBundleIDs;
    static NSSet<NSString *> *chromeOwnerNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chromeBundleIDs = [NSSet setWithArray:@[
            @"com.apple.dock",
            @"com.apple.controlcenter",
            @"com.apple.notificationcenterui",
        ]];
        // The Window Server has no NSRunningApplication, so match it by owner name.
        chromeOwnerNames = [NSSet setWithArray:@[ @"Window Server", @"WindowServer" ]];
    });

    if (ownerName && [chromeOwnerNames containsObject:ownerName]) {
        return YES;
    }

    NSString *bundleID = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    return bundleID != nil && [chromeBundleIDs containsObject:bundleID];
}


- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point locationID:(uint32_t)locationID {

    if ([self isPointInMenuBar:point locationID:locationID]) {
        return NO;
    }

    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];

    CFArrayRef array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);

    // The window list is ordered front-to-back by window *level* (not grouped by app), so
    // high-level overlays — including our own screenSaver-level panels — come before the
    // active app's normal windows. `behindFrontmostWindow` flips once we pass the active
    // app's topmost window: windows seen before it are stacked above it, windows after are
    // behind it.
    BOOL behindFrontmostWindow = NO;
    BOOL res = NO;

    for (CFIndex i=0; i<CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);

        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType,  &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;

        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);

        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }

        if (!isInside) continue;

        NSString *ownerName = (__bridge NSString *)CFDictionaryGetValue(dic, kCGWindowOwnerName);
        if ([self isSystemChromeOwner:currPID name:ownerName]) {
            continue;
        }

        // First real window under the point = the one the finger actually hits.
        if (isFrontmostApp) {
            res = NO;   // already the active window — the tap actuates it directly
        } else if (!behindFrontmostWindow) {
            res = NO;   // stacked above the active app (an overlay or our own panel) — takes the tap directly
        } else {
            // A background window of another app — normally inject a click to raise it.
            // Exception: the title bar. A background title bar accepts clicks directly, so
            // our injected raise-click plus the tap's own click would register as a
            // title-bar double-click (→ zoom/fullscreen). A single tap already raises the
            // window, so skip the extra click within the title-bar strip.
            //
            // CGWindowList can't tell us the actual title-bar/toolbar height, so this is a
            // heuristic constant. Erring high (toolbars on Tahoe are tall) costs at most a
            // missed raise-click near the top of a background window; erring low brings the
            // destructive double-click-zoom back.
            CGFloat titleBarHeight = 44;
            BOOL inTitleBar = (point.y - nextFrame.origin.y) <= titleBarHeight;
            res = inTitleBar ? NO : YES;
        }
        break;
    }

    CFRelease(array);
    return res;
}




#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
        
        self.frameIDsByLocationID = [NSMutableDictionary new];
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.08;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        if (touch.contactID == self.cursorTouch.contactID) {
            [str appendString: @" <<<CURSOR>>>\n" ];
        } else {
            [str appendString: @"\n" ];
        }
    }
    
    [str appendString:@"}"];
    return str;
}

- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}



#pragma mark - Bridge calls of C Header to Objective-C

void TouchInputManagerUpdateTouchPosition(void *self, uint32_t locationID, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid) {
    CGPoint point = CGPointMake(x, y);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withLocation:point onSurface:onSurface tooLargeForFinger:isValid];
}

void TouchInputManagerUpdateTouchSize(void *self, uint32_t locationID, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth) {
    CGSize size = CGSizeMake(width, height);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withSize:size azimuth:azimuth];
}

void TouchInputManagerDidProcessReport(void *self, uint32_t locationID) {
    [(__bridge id)self didProcessReportForLocationID:locationID];
}

void TouchInputManagerDidConnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didConnectTouchscreenWithLocationID:locationID];
}

void TouchInputManagerDidDisconnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didDisconnectTouchscreenWithLocationID:locationID];
}

static CGPoint RackTargetPoint(TUCTouchInputManager *manager,
                               uint32_t locationID,
                               CGFloat x,
                               CGFloat y) {
    CGPoint glassPoint = CGPointMake(x, y);
    CGPoint relativePoint = [manager convertDigitizerPointToRelativeScreenPoint:glassPoint
                                                                      locationID:locationID];
    return [manager convertScreenPointRelativeToAbsolute:relativePoint
                                               locationID:locationID];
}

static CGPoint RackSafeRestorePoint(TUCTouchInputManager *manager,
                                    uint32_t locationID) {
    TUCCursorUtilities *cursor = [TUCCursorUtilities sharedInstance];
    CGPoint savedCursorPoint = [cursor currentCursorLocation];
    TUCScreen *rackScreen = [manager touchscreenForLocationID:locationID];
    CGPoint restorePoint = savedCursorPoint;

    // WindowServer may process the controller's mouse-compatible event before
    // the bridged report reaches us. If that already displaced the cursor onto
    // the rack panel, restore to the centre of JetKVM instead of saving the
    // contaminated rack coordinate.
    if (rackScreen && CGRectContainsPoint(rackScreen.frame, savedCursorPoint)) {
        TUCScreen *restoreScreen = RackPreferredRestoreScreen(rackScreen);
        if (restoreScreen) {
            restorePoint = CGPointMake(CGRectGetMidX(restoreScreen.frame),
                                       CGRectGetMidY(restoreScreen.frame));
        }
    }
    return restorePoint;
}

static TUCScreen *RackPreferredRestoreScreen(TUCScreen *rackScreen) {
    TUCScreen *mainScreen = nil;
    TUCScreen *firstNonRackScreen = nil;
    for (TUCScreen *screen in [TUCScreen allScreens]) {
        if (rackScreen && screen.id == rackScreen.id) continue;
        if ([screen.name isEqualToString:kRackTouchRestoreDisplayName]) return screen;
        if (screen.id == CGMainDisplayID()) mainScreen = screen;
        if (!firstNonRackScreen) firstNonRackScreen = screen;
    }
    // Display adapters and KVM firmware can change their EDID product name.
    // The main non-rack display is the safest fallback, followed by any other
    // non-rack display, so a contaminated rack coordinate is never retained.
    return mainScreen ?: firstNonRackScreen;
}

static pid_t RackWindowPIDAtPoint(CGPoint point) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                    kCGWindowListExcludeDesktopElements,
                                                    kCGNullWindowID);
    if (!windows) return 0;

    pid_t ownPID = [NSProcessInfo processInfo].processIdentifier;
    pid_t targetPID = 0;
    for (CFIndex index = 0; index < CFArrayGetCount(windows); index++) {
        NSDictionary *window = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windows, index);
        if ([window[(id)kCGWindowLayer] integerValue] != 0) continue;

        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],
                                                    &bounds) ||
            !CGRectContainsPoint(bounds, point)) continue;

        pid_t candidate = (pid_t)[window[(id)kCGWindowOwnerPID] intValue];
        if (candidate > 0 && candidate != ownPID) {
            targetPID = candidate;
            break;
        }
    }
    CFRelease(windows);
    return targetPID;
}

static int64_t RackNextMouseEventNumber(void) {
    static int64_t eventNumber = 100000;
    return ++eventNumber;
}

static BOOL RackSliderBoundsAtPoint(CGPoint point, CGRect *bounds) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(systemWide, point.x, point.y, &element);
    CFRelease(systemWide);
    if (error != kAXErrorSuccess || !element) return NO;

    BOOL found = NO;
    for (NSUInteger depth = 0; depth < 8 && element && !found; depth++) {
        CFTypeRef roleValue = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &roleValue) == kAXErrorSuccess &&
            roleValue && CFGetTypeID(roleValue) == CFStringGetTypeID() &&
            CFEqual(roleValue, kAXSliderRole)) {
            CFTypeRef positionValue = NULL;
            CFTypeRef sizeValue = NULL;
            CGPoint origin = CGPointZero;
            CGSize size = CGSizeZero;
            if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &positionValue) == kAXErrorSuccess &&
                AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess &&
                positionValue && sizeValue &&
                CFGetTypeID(positionValue) == AXValueGetTypeID() &&
                CFGetTypeID(sizeValue) == AXValueGetTypeID() &&
                AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &origin) &&
                AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size)) {
                *bounds = CGRectInset(CGRectMake(origin.x, origin.y, size.width, size.height), 1.0, 1.0);
                found = !CGRectIsEmpty(*bounds);
            }
            if (positionValue) CFRelease(positionValue);
            if (sizeValue) CFRelease(sizeValue);
        }
        if (roleValue) CFRelease(roleValue);
        if (found) break;

        CFTypeRef parentValue = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXParentAttribute, &parentValue) != kAXErrorSuccess ||
            !parentValue || CFGetTypeID(parentValue) != AXUIElementGetTypeID()) {
            if (parentValue) CFRelease(parentValue);
            break;
        }
        CFRelease(element);
        element = (AXUIElementRef)parentValue;
    }
    if (element) CFRelease(element);
    return found;
}

static CGPoint RackConstrainDragPoint(TUCTouchInputManager *manager, CGPoint point) {
    if (!manager.rackSyntheticDragConstrained) return point;
    CGRect bounds = manager.rackSyntheticDragConstraintRect;
    point.x = fmin(fmax(point.x, CGRectGetMinX(bounds)), CGRectGetMaxX(bounds));
    point.y = fmin(fmax(point.y, CGRectGetMinY(bounds)), CGRectGetMaxY(bounds));
    return point;
}

static void RackPostScrollEvent(CGPoint point, CGPoint translation) {
    if (fabs(translation.x) < 0.01 && fabs(translation.y) < 0.01) return;
    CGEventRef event = CGEventCreateScrollWheelEvent2(NULL,
                                                      kCGScrollEventUnitPixel,
                                                      2,
                                                      translation.y,
                                                      translation.x,
                                                      0);
    if (!event) return;
    // Scroll events otherwise inherit the JetKVM cursor position and Safari
    // sends them to the wrong window. Preserve the visible cursor while routing
    // this event to the rack window under the finger.
    CGEventSetLocation(event, point);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void RackPostMouseMove(CGPoint point) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                               point, kCGMouseButtonLeft);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void RackPostMouseEvent(CGEventType type,
                               CGPoint point,
                               int64_t eventNumber,
                               pid_t targetPID) {
    (void)targetPID;
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, kCGMouseButtonLeft);
    if (!event) return;
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, eventNumber);
    CGEventSetDoubleValueField(event, kCGMouseEventPressure,
                               type == kCGEventLeftMouseUp ? 0.0 : 1.0);
    // Safari does not consistently accept a complete synthetic drag delivered
    // with CGEventPostToPid. Post through WindowServer so down/drag/up retain
    // normal pointer-grab semantics; the cursor stays hidden and is restored
    // only after the receiving app has consumed mouse-up.
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static BOOL RackCursorIsCurrentlyVisible(void) {
    typedef boolean_t (*RackCursorIsVisibleFunction)(void);
    static RackCursorIsVisibleFunction cursorIsVisible;
    static dispatch_once_t cursorVisibilityOnce;
    dispatch_once(&cursorVisibilityOnce, ^{
        cursorIsVisible = (RackCursorIsVisibleFunction)dlsym(RTLD_DEFAULT,
                                                              "CGCursorIsVisible");
    });
    return cursorIsVisible ? cursorIsVisible() : NO;
}

static void RackEnsureCursorHidden(TUCTouchInputManager *manager) {
    if (!manager.rackCursorHideRequested) {
        // Public cursor hiding normally only affects the foreground process.
        // Enable the established background-utility compatibility property,
        // resolving it dynamically so future macOS versions can fall back.
        typedef int32_t (*RackDefaultConnectionFunction)(void);
        typedef CGError (*RackSetConnectionPropertyFunction)(int32_t, int32_t,
                                                              CFStringRef, CFTypeRef);
        static dispatch_once_t backgroundCursorOnce;
        dispatch_once(&backgroundCursorOnce, ^{
            RackDefaultConnectionFunction defaultConnection =
                (RackDefaultConnectionFunction)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
            RackSetConnectionPropertyFunction setConnectionProperty =
                (RackSetConnectionPropertyFunction)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
            if (defaultConnection && setConnectionProperty) {
                int32_t connection = defaultConnection();
                setConnectionProperty(connection, connection,
                                      CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
            }
        });
        CGDisplayHideCursor(CGMainDisplayID());
        manager.rackCursorHideBalance += 1;
        manager.rackCursorHideRequested = YES;
        return;
    }

    // WindowServer or the receiving app can occasionally re-show the cursor
    // while processing a synthetic click/drag. Re-hide only when CoreGraphics
    // confirms it is actually visible, avoiding unbalanced hide counts.
    if (RackCursorIsCurrentlyVisible()) {
        CGDisplayHideCursor(CGMainDisplayID());
        manager.rackCursorHideBalance += 1;
    }
}

static void RackForceCursorRestore(TUCTouchInputManager *manager) {
    // App shutdown can occur before a scheduled 50 ms restore runs. Invalidate
    // every delayed block, clear synthetic state, restore pointer association,
    // and drain only the hide requests this manager issued.
    manager.rackCursorRestoreGeneration += 1;
    manager.rackSyntheticDragActive = NO;
    manager.rackSyntheticScrollActive = NO;
    manager.rackSyntheticPinchActive = NO;
    manager.rackChromeRevealActive = NO;
    manager.rackTopEdgeRevealCandidate = NO;

    TUCScreen *rackScreen = nil;
    for (TUCScreen *screen in [TUCScreen allScreens]) {
        if ([screen.name isEqualToString:kRackTouchDisplayName]) {
            rackScreen = screen;
            break;
        }
    }
    TUCScreen *restoreScreen = RackPreferredRestoreScreen(rackScreen);
    if (restoreScreen) {
        CGPoint restorePoint = CGPointMake(CGRectGetMidX(restoreScreen.frame),
                                           CGRectGetMidY(restoreScreen.frame));
        CGAssociateMouseAndMouseCursorPosition(true);
        CGWarpMouseCursorPosition(restorePoint);
    }
    while (manager.rackCursorHideBalance > 0) {
        CGDisplayShowCursor(CGMainDisplayID());
        manager.rackCursorHideBalance -= 1;
    }
    manager.rackCursorHideRequested = NO;
    fprintf(stderr, "Rack cursor force-restored on stop.\n");
}

static void RackScheduleCursorRestoreAfter(TUCTouchInputManager *manager,
                                           CGPoint point,
                                           NSTimeInterval delay) {
    NSUInteger generation = manager.rackCursorRestoreGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (manager.rackCursorRestoreGeneration != generation ||
            manager.rackSyntheticDragActive || manager.rackSyntheticScrollActive ||
            manager.rackSyntheticPinchActive || manager.rackChromeRevealActive) return;
        // A silent warp does not tell Safari that the pointer left the top
        // edge, so fullscreen chrome can remain latched. Post a genuine move
        // while the cursor is still hidden, then enforce the final position.
        RackPostMouseMove(point);
        CGWarpMouseCursorPosition(point);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.03 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (manager.rackCursorRestoreGeneration != generation ||
                manager.rackSyntheticDragActive || manager.rackSyntheticScrollActive ||
                manager.rackSyntheticPinchActive || manager.rackChromeRevealActive) return;
            if (manager.rackCursorHideRequested) {
                while (manager.rackCursorHideBalance > 0) {
                    CGDisplayShowCursor(CGMainDisplayID());
                    manager.rackCursorHideBalance -= 1;
                }
                manager.rackCursorHideRequested = NO;
            }
        });
    });
}

static void RackScheduleCursorRestore(TUCTouchInputManager *manager, CGPoint point) {
    RackScheduleCursorRestoreAfter(manager, point, 0.05);
}

static BOOL RackShouldPromoteScrollToHorizontalDrag(TUCTouchInputManager *manager,
                                                    CGPoint targetPoint) {
    CGFloat totalX = targetPoint.x - manager.rackSyntheticScrollStartPoint.x;
    CGFloat totalY = targetPoint.y - manager.rackSyntheticScrollStartPoint.y;
    return fabs(totalX) >= 12.0 && fabs(totalX) >= fabs(totalY) * 1.5;
}

static void RackPromoteScrollToHorizontalDrag(TUCTouchInputManager *manager,
                                              CGPoint targetPoint) {
    manager.rackSyntheticScrollActive = NO;
    manager.rackTopEdgeRevealCandidate = NO;
    manager.rackSyntheticDragActive = YES;
    // Home Assistant's custom web-component sliders are not always exposed as
    // AXSlider. Their backdrop can interpret a mouse-up outside the modal as a
    // click-away even after a valid drag. Preserve the final value with the
    // last dragged event, then release at the original slider point so the
    // down/up targets share the control rather than its modal backdrop.
    manager.rackSyntheticDragReleaseAtStart = YES;
    manager.rackSyntheticDragLastPoint = targetPoint;
    RackPostMouseEvent(kCGEventLeftMouseDown,
                       manager.rackSyntheticScrollStartPoint,
                       manager.rackSyntheticDragEventNumber,
                       manager.rackSyntheticDragTargetPID);
    RackPostMouseEvent(kCGEventLeftMouseDragged,
                       targetPoint,
                       manager.rackSyntheticDragEventNumber,
                       manager.rackSyntheticDragTargetPID);
    RackEnsureCursorHidden(manager);
}

static void RackLogAccessibilityOnce(void) {
    static dispatch_once_t accessibilityLogOnce;
    dispatch_once(&accessibilityLogOnce, ^{
        NSLog(@"Touch Up Accessibility access: %@; event-post access: %@",
              AXIsProcessTrusted() ? @"granted" : @"denied",
              CGPreflightPostEventAccess() ? @"granted" : @"denied");
    });
}

static void RackPostMagnifyEvent(CGPoint point,
                                 CGFloat magnification,
                                 NSTouchPhase phase,
                                 pid_t targetPID) {
    (void)targetPID;
    // Touch Up's upstream magnify implementation uses Quartz gesture event 29.
    // Construct it at the rack midpoint directly instead of first posting a
    // mouse-move, so the visible system cursor can remain on JetKVM.
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                               point, kCGMouseButtonLeft);
    if (!event) return;
    CGEventSetType(event, 29);
    CGEventSetFlags(event, 0);
    CGEventSetDoubleValueField(event, 113, magnification);
    CGEventSetDoubleValueField(event, 114, magnification);
    CGEventSetDoubleValueField(event, 116, magnification);
    CGEventSetDoubleValueField(event, 118, magnification);
    CGEventSetIntegerValueField(event, 50, 248);
    CGEventSetIntegerValueField(event, 101, 4);
    CGEventSetIntegerValueField(event, 110, 8);
    CGEventSetIntegerValueField(event, 132, phase);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static CGFloat RackPinchDistance(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    CGFloat dx = x1 - x2;
    CGFloat dy = y1 - y2;
    return sqrt(dx * dx + dy * dy);
}

static CGPoint RackPinchMidpoint(TUCTouchInputManager *manager,
                                 uint32_t locationID,
                                 CGFloat x1, CGFloat y1,
                                 CGFloat x2, CGFloat y2) {
    CGPoint p1 = RackTargetPoint(manager, locationID, x1, y1);
    CGPoint p2 = RackTargetPoint(manager, locationID, x2, y2);
    return CGPointMake((p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5);
}

void TouchInputManagerPerformRackTap(void *self, uint32_t locationID, CGFloat x, CGFloat y) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    [manager cancelRackSyntheticDrag];
    CGPoint targetPoint = RackTargetPoint(manager, locationID, x, y);
    TUCCursorUtilities *cursor = [TUCCursorUtilities sharedInstance];
    CGPoint restorePoint = RackSafeRestorePoint(manager, locationID);
    RackLogAccessibilityOnce();

    // A move-to-touch followed by a delayed click makes Safari's auto-hidden
    // toolbar and the macOS menu bar reveal before the dashboard receives the
    // click. Post the down/up pair atomically, with the pointer hidden, then
    // restore the remote-console cursor without generating another click.
    manager.rackCursorRestoreGeneration += 1;
    RackEnsureCursorHidden(manager);
    [cursor performClickAt:targetPoint];
    RackEnsureCursorHidden(manager);
    RackScheduleCursorRestore(manager, restorePoint);
}

void TouchInputManagerPerformRackSecondaryTap(void *self, uint32_t locationID,
                                               CGFloat x, CGFloat y) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    [manager cancelRackSyntheticDrag];
    CGPoint targetPoint = RackTargetPoint(manager, locationID, x, y);
    TUCCursorUtilities *cursor = [TUCCursorUtilities sharedInstance];
    CGPoint restorePoint = RackSafeRestorePoint(manager, locationID);
    RackLogAccessibilityOnce();

    manager.rackCursorRestoreGeneration += 1;
    RackEnsureCursorHidden(manager);
    [cursor performSecondaryClickAt:targetPoint];
    RackEnsureCursorHidden(manager);
    RackScheduleCursorRestore(manager, restorePoint);
}

void TouchInputManagerBeginRackDrag(void *self, uint32_t locationID, CGFloat x, CGFloat y) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    [manager cancelRackSyntheticDrag];
    RackLogAccessibilityOnce();

    CGPoint targetPoint = RackTargetPoint(manager, locationID, x, y);
    manager.rackSyntheticDragRestorePoint = RackSafeRestorePoint(manager, locationID);
    manager.rackSyntheticDragStartPoint = targetPoint;
    manager.rackSyntheticDragLastPoint = targetPoint;
    manager.rackSyntheticDragTargetPID = RackWindowPIDAtPoint(targetPoint);
    manager.rackSyntheticDragEventNumber = RackNextMouseEventNumber();
    CGRect constraintRect = CGRectZero;
    manager.rackSyntheticDragConstrained = RackSliderBoundsAtPoint(targetPoint,
                                                                    &constraintRect);
    manager.rackSyntheticDragReleaseAtStart = NO;
    manager.rackSyntheticDragConstraintRect = constraintRect;
    manager.rackCursorRestoreGeneration += 1;

    RackEnsureCursorHidden(manager);
    if (!manager.rackSyntheticDragConstrained) {
        // A finger movement over ordinary page content should behave like a
        // touchscreen scroll, not a mouse drag that selects text. Actual AX
        // sliders retain the captured mouse down/drag/up path below.
        manager.rackSyntheticScrollRestorePoint = manager.rackSyntheticDragRestorePoint;
        manager.rackSyntheticScrollLastPoint = targetPoint;
        manager.rackSyntheticScrollStartPoint = targetPoint;
        TUCScreen *rackScreen = [manager touchscreenForLocationID:locationID];
        CGFloat localStartY = targetPoint.y - CGRectGetMinY(rackScreen.frame);
        // A 24-point strip was narrower than a fingertip on this 75 mm-tall
        // panel, so valid edge pulls were often classified as ordinary scrolls.
        // Keep the strip small enough not to steal dashboard scrolling while
        // allowing a deliberate contact just below Safari's visible chrome.
        manager.rackTopEdgeRevealCandidate =
            localStartY >= 0.0 && localStartY <= kRackTopEdgeStartZone;
        manager.rackSyntheticScrollActive = YES;
        return;
    }

    manager.rackSyntheticDragActive = YES;
    RackPostMouseEvent(kCGEventLeftMouseDown, targetPoint,
                       manager.rackSyntheticDragEventNumber,
                       manager.rackSyntheticDragTargetPID);
}

void TouchInputManagerUpdateRackDrag(void *self, uint32_t locationID, CGFloat x, CGFloat y) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    if (manager.rackSyntheticScrollActive) {
        CGPoint targetPoint = RackTargetPoint(manager, locationID, x, y);
        if (manager.rackTopEdgeRevealCandidate) {
            CGFloat totalX = targetPoint.x - manager.rackSyntheticScrollStartPoint.x;
            CGFloat totalY = targetPoint.y - manager.rackSyntheticScrollStartPoint.y;
            if (totalY >= kRackTopEdgeRevealDistance && fabs(totalX) <= totalY * 2.0) {
                TUCScreen *rackScreen = [manager touchscreenForLocationID:locationID];
                CGFloat edgeY = CGRectGetMinY(rackScreen.frame);
                CGPoint approachPoint = CGPointMake(targetPoint.x,
                                                    edgeY + kRackTopEdgeApproachInset);
                CGPoint edgePoint = CGPointMake(targetPoint.x, edgeY);
                manager.rackTopEdgeRevealCandidate = NO;
                manager.rackSyntheticScrollActive = NO;
                manager.rackChromeRevealActive = YES;

                // Safari's auto-hidden toolbar does not reliably react to a
                // single teleport from another display to the exact edge. Give
                // WindowServer a real inside-to-edge trajectory on consecutive
                // run-loop turns. The generation check prevents a delayed edge
                // move from racing a newer tap or gesture.
                NSUInteger revealGeneration = manager.rackCursorRestoreGeneration;
                RackPostMouseMove(approachPoint);
                RackEnsureCursorHidden(manager);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.04 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (manager.rackCursorRestoreGeneration != revealGeneration) return;
                    RackPostMouseMove(edgePoint);
                    RackEnsureCursorHidden(manager);
                });
                return;
            }
            // Reserve a deliberate downward pull, but fall back to ordinary
            // scrolling as soon as the trajectory is upward or strongly
            // horizontal. Include the deferred movement in that first event.
            if (totalY >= 0.0 && totalY < kRackTopEdgeRevealDistance &&
                fabs(totalX) <= kRackTopEdgeStartZone) return;
            manager.rackTopEdgeRevealCandidate = NO;
            if (RackShouldPromoteScrollToHorizontalDrag(manager, targetPoint)) {
                RackPromoteScrollToHorizontalDrag(manager, targetPoint);
                return;
            }
            CGPoint deferred = CGPointMake(totalX, totalY);
            manager.rackSyntheticScrollLastPoint = targetPoint;
            RackPostScrollEvent(targetPoint, deferred);
            RackEnsureCursorHidden(manager);
            return;
        }
        if (RackShouldPromoteScrollToHorizontalDrag(manager, targetPoint)) {
            RackPromoteScrollToHorizontalDrag(manager, targetPoint);
            return;
        }
        CGPoint translation = CGPointMake(targetPoint.x - manager.rackSyntheticScrollLastPoint.x,
                                          targetPoint.y - manager.rackSyntheticScrollLastPoint.y);
        manager.rackSyntheticScrollLastPoint = targetPoint;
        RackPostScrollEvent(targetPoint, translation);
        RackEnsureCursorHidden(manager);
        return;
    }
    if (manager.rackChromeRevealActive) {
        RackEnsureCursorHidden(manager);
        return;
    }
    if (!manager.rackSyntheticDragActive) return;

    CGPoint targetPoint = RackConstrainDragPoint(
        manager, RackTargetPoint(manager, locationID, x, y));
    manager.rackSyntheticDragLastPoint = targetPoint;
    RackPostMouseEvent(kCGEventLeftMouseDragged, targetPoint,
                       manager.rackSyntheticDragEventNumber,
                       manager.rackSyntheticDragTargetPID);
    RackEnsureCursorHidden(manager);
}

void TouchInputManagerEndRackDrag(void *self, uint32_t locationID, CGFloat x, CGFloat y) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    if (manager.rackChromeRevealActive) {
        manager.rackChromeRevealActive = NO;
        // Leave the pointer at the edge long enough for Safari/macOS chrome to
        // animate in and accept a follow-up touch, but always return to JetKVM.
        RackScheduleCursorRestoreAfter(manager, manager.rackSyntheticScrollRestorePoint, 2.0);
        return;
    }
    if (manager.rackSyntheticScrollActive) {
        CGPoint targetPoint = RackTargetPoint(manager, locationID, x, y);
        CGPoint translation = CGPointMake(targetPoint.x - manager.rackSyntheticScrollLastPoint.x,
                                          targetPoint.y - manager.rackSyntheticScrollLastPoint.y);
        RackPostScrollEvent(targetPoint, translation);
        manager.rackSyntheticScrollActive = NO;
        manager.rackTopEdgeRevealCandidate = NO;
        RackScheduleCursorRestore(manager, manager.rackSyntheticScrollRestorePoint);
        return;
    }
    if (!manager.rackSyntheticDragActive) return;

    CGPoint targetPoint = RackConstrainDragPoint(
        manager, RackTargetPoint(manager, locationID, x, y));
    RackPostMouseEvent(kCGEventLeftMouseDragged, targetPoint,
                       manager.rackSyntheticDragEventNumber,
                       manager.rackSyntheticDragTargetPID);
    CGPoint releasePoint = manager.rackSyntheticDragReleaseAtStart
        ? manager.rackSyntheticDragStartPoint : targetPoint;
    RackPostMouseEvent(kCGEventLeftMouseUp, releasePoint,
                       manager.rackSyntheticDragEventNumber,
                       manager.rackSyntheticDragTargetPID);
    RackEnsureCursorHidden(manager);
    manager.rackSyntheticDragActive = NO;
    manager.rackSyntheticDragConstrained = NO;
    manager.rackSyntheticDragReleaseAtStart = NO;
    RackScheduleCursorRestore(manager, manager.rackSyntheticDragRestorePoint);
}

void TouchInputManagerCancelRackDrag(void *self) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    [manager cancelRackSyntheticDrag];
}

- (void)cancelRackSyntheticDrag {
    if (self.rackChromeRevealActive) {
        self.rackChromeRevealActive = NO;
        RackScheduleCursorRestore(self, self.rackSyntheticScrollRestorePoint);
        return;
    }
    if (self.rackSyntheticScrollActive) {
        self.rackSyntheticScrollActive = NO;
        self.rackTopEdgeRevealCandidate = NO;
        RackScheduleCursorRestore(self, self.rackSyntheticScrollRestorePoint);
        return;
    }
    if (!self.rackSyntheticDragActive) return;

    CGPoint releasePoint = self.rackSyntheticDragReleaseAtStart
        ? self.rackSyntheticDragStartPoint : self.rackSyntheticDragLastPoint;
    RackPostMouseEvent(kCGEventLeftMouseUp, releasePoint,
                       self.rackSyntheticDragEventNumber,
                       self.rackSyntheticDragTargetPID);
    self.rackSyntheticDragActive = NO;
    self.rackSyntheticDragConstrained = NO;
    self.rackSyntheticDragReleaseAtStart = NO;
    RackScheduleCursorRestore(self, self.rackSyntheticDragRestorePoint);
}

void TouchInputManagerBeginRackPinch(void *self, uint32_t locationID,
                                    CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    [manager cancelRackSyntheticDrag];
    [manager cancelRackSyntheticPinch];
    RackLogAccessibilityOnce();

    manager.rackSyntheticPinchRestorePoint = RackSafeRestorePoint(manager, locationID);
    manager.rackSyntheticPinchLastPoint = RackPinchMidpoint(manager, locationID,
                                                           x1, y1, x2, y2);
    manager.rackSyntheticPinchLastDistance = RackPinchDistance(x1, y1, x2, y2);
    manager.rackSyntheticPinchTargetPID = RackWindowPIDAtPoint(manager.rackSyntheticPinchLastPoint);
    manager.rackCursorRestoreGeneration += 1;
    manager.rackSyntheticPinchActive = YES;
    RackEnsureCursorHidden(manager);
    RackPostMagnifyEvent(manager.rackSyntheticPinchLastPoint, 0.0,
                         NSTouchPhaseBegan, manager.rackSyntheticPinchTargetPID);
}

void TouchInputManagerUpdateRackPinch(void *self, uint32_t locationID,
                                     CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    if (!manager.rackSyntheticPinchActive) return;

    CGFloat distance = RackPinchDistance(x1, y1, x2, y2);
    CGFloat delta = distance - manager.rackSyntheticPinchLastDistance;
    manager.rackSyntheticPinchLastDistance = distance;
    manager.rackSyntheticPinchLastPoint = RackPinchMidpoint(manager, locationID,
                                                            x1, y1, x2, y2);
    if (fabs(delta) > 0.00001) {
        RackPostMagnifyEvent(manager.rackSyntheticPinchLastPoint,
                             delta * 4.0, NSTouchPhaseMoved,
                             manager.rackSyntheticPinchTargetPID);
    }
}

void TouchInputManagerEndRackPinch(void *self) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    if (!manager.rackSyntheticPinchActive) return;

    RackPostMagnifyEvent(manager.rackSyntheticPinchLastPoint, 0.0,
                         NSTouchPhaseEnded, manager.rackSyntheticPinchTargetPID);
    manager.rackSyntheticPinchActive = NO;
    RackScheduleCursorRestore(manager, manager.rackSyntheticPinchRestorePoint);
}

void TouchInputManagerCancelRackPinch(void *self) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)self;
    [manager cancelRackSyntheticPinch];
}

- (void)cancelRackSyntheticPinch {
    if (!self.rackSyntheticPinchActive) return;

    RackPostMagnifyEvent(self.rackSyntheticPinchLastPoint, 0.0,
                         NSTouchPhaseEnded, self.rackSyntheticPinchTargetPID);
    self.rackSyntheticPinchActive = NO;
    RackScheduleCursorRestore(self, self.rackSyntheticPinchRestorePoint);
}


@end
