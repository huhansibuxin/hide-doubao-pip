#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <time.h>

static FILE *logFile = NULL;
static const NSUInteger kMaxLogSize = 512 * 1024;
static NSString *const kLogPath = @"/var/mobile/Documents/PiPArrowHide.log";
static const NSTimeInterval kPiPWindowCountCacheInterval = 0.10;
static NSTimeInterval sLastPiPWindowCountCheckTime = 0;
static BOOL sLastHasMultipleActivePiPWindows = NO;

typedef NS_ENUM(NSInteger, DoubaoPiPIdentity) {
    DoubaoPiPIdentityUnknown = 0,
    DoubaoPiPIdentityDoubao,
    DoubaoPiPIdentityNonDoubao,
};

static void WriteLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void WriteLog(NSString *format, ...) {
    struct stat st;
    BOOL shouldResetLog = stat(kLogPath.UTF8String, &st) == 0 && (NSUInteger)st.st_size >= kMaxLogSize;
    if (logFile && shouldResetLog) {
        fclose(logFile);
        logFile = NULL;
    }
    if (!logFile) {
        logFile = fopen(kLogPath.UTF8String, shouldResetLog ? "w" : "a");
    }
    if (!logFile) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    time_t rawTime;
    time(&rawTime);
    struct tm timeInfo;
    localtime_r(&rawTime, &timeInfo);
    char ts[16];
    strftime(ts, sizeof(ts), "%H:%M:%S", &timeInfo);
    fprintf(logFile, "[%s] %s\n", ts, msg.UTF8String);
    fflush(logFile);
}

static BOOL IsTargetBundleID(id value) {
    return [value isKindOfClass:[NSString class]] &&
           ([(NSString *)value isEqualToString:@"com.bytedance.ios.doubaoime"] ||
            [(NSString *)value isEqualToString:@"com.tencent.wetype"]);
}

static DoubaoPiPIdentity IdentityFromBundleID(id value) {
    if (![value isKindOfClass:[NSString class]]) return DoubaoPiPIdentityUnknown;

    NSString *bundleID = (NSString *)value;
    if (bundleID.length == 0) return DoubaoPiPIdentityUnknown;
    return IsTargetBundleID(bundleID) ? DoubaoPiPIdentityDoubao : DoubaoPiPIdentityNonDoubao;
}

static id SafeKVC(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *SafeClassName(id object) {
    if (!object) return nil;
    @try {
        return NSStringFromClass(object_getClass(object));
    } @catch (NSException *e) {
        return nil;
    }
}

static DoubaoPiPIdentity IdentityFromProcess(id process) {
    if (!process) return DoubaoPiPIdentityUnknown;

    @try {
        if ([process respondsToSelector:@selector(bundleIdentifier)]) {
            DoubaoPiPIdentity identity = IdentityFromBundleID([process performSelector:@selector(bundleIdentifier)]);
            if (identity != DoubaoPiPIdentityUnknown) return identity;
        }
        if ([process respondsToSelector:@selector(bundleID)]) {
            DoubaoPiPIdentity identity = IdentityFromBundleID([process performSelector:@selector(bundleID)]);
            if (identity != DoubaoPiPIdentityUnknown) return identity;
        }
    } @catch (NSException *e) {}

    DoubaoPiPIdentity identity = IdentityFromBundleID(SafeKVC(process, @"bundleIdentifier"));
    if (identity != DoubaoPiPIdentityUnknown) return identity;

    return IdentityFromBundleID(SafeKVC(process, @"bundleID"));
}

static DoubaoPiPIdentity IdentityFromPegasusApp(id pipCtrl) {
    if (!pipCtrl) return DoubaoPiPIdentityUnknown;

    id adapter = SafeKVC(pipCtrl, @"_adapter");
    if (!adapter) return DoubaoPiPIdentityUnknown;

    id pegasus = SafeKVC(adapter, @"_pegasusController");
    if (!pegasus) return DoubaoPiPIdentityUnknown;

    id activeApp = SafeKVC(pegasus, @"_activePictureInPictureApplication");
    if (!activeApp) return DoubaoPiPIdentityUnknown;

    return IdentityFromBundleID(SafeKVC(activeApp, @"_bundleIdentifier"));
}

static DoubaoPiPIdentity IdentityFromPiPControllerLocal(id pipCtrl) {
    if (!pipCtrl) return DoubaoPiPIdentityUnknown;

    NSArray *bundleKeys = @[
        @"_bundleIDForAppAnimatingPIPStartInBackground",
        @"_bundleIDForAppRecentlyStoppingPIP"
    ];
    for (NSString *key in bundleKeys) {
        DoubaoPiPIdentity identity = IdentityFromBundleID(SafeKVC(pipCtrl, key));
        if (identity != DoubaoPiPIdentityUnknown) return identity;
    }

    NSArray *processKeys = @[@"_pipProcess", @"_applicationProcess"];
    for (NSString *key in processKeys) {
        DoubaoPiPIdentity identity = IdentityFromProcess(SafeKVC(pipCtrl, key));
        if (identity != DoubaoPiPIdentityUnknown) return identity;
    }

    return DoubaoPiPIdentityUnknown;
}

static BOOL IsPiPWindow(UIWindow *window) {
    return [SafeClassName(window) isEqualToString:@"SBPictureInPictureWindow"];
}

static BOOL IsVisiblePiPWindow(UIWindow *window) {
    return IsPiPWindow(window) && !window.hidden && window.alpha > 0.01;
}

static UIView *FindViewByClassName(UIView *view, NSString *className, NSUInteger maxDepth) {
    if (!view || className.length == 0) return nil;
    if ([SafeClassName(view) isEqualToString:className]) return view;
    if (maxDepth == 0) return nil;

    for (UIView *subview in view.subviews) {
        UIView *found = FindViewByClassName(subview, className, maxDepth - 1);
        if (found) return found;
    }
    return nil;
}

static NSUInteger CountDirectSubviewClass(UIView *view, NSString *className, BOOL hidden) {
    if (!view || className.length == 0) return 0;

    NSUInteger count = 0;
    for (UIView *subview in view.subviews) {
        if ([SafeClassName(subview) isEqualToString:className] && subview.hidden == hidden) {
            count++;
        }
    }
    return count;
}

static BOOL ViewIsHiddenOrTransparent(UIView *view) {
    return !view || view.hidden || view.alpha < 0.05;
}

static BOOL RectLooksLikeDoubaoPiP(CGRect rect) {
    CGFloat width = CGRectGetWidth(rect);
    CGFloat height = CGRectGetHeight(rect);
    if (width < 160.0 || width > 260.0 || height < 90.0 || height > 150.0) return NO;

    CGFloat aspect = width / MAX(height, 1.0);
    return aspect > 1.55 && aspect < 1.95;
}

static BOOL IsLikelyDoubaoPiPWindowByViewTree(UIWindow *window) {
    UIView *rootView = window.rootViewController.view;
    if (!rootView) return NO;

    UIView *hitTestView = FindViewByClassName(rootView, @"PGHitTestExtendableView", 8);
    if (!hitTestView || !RectLooksLikeDoubaoPiP(hitTestView.frame)) return NO;

    UIView *layoutView = FindViewByClassName(rootView, @"PGLayoutContainerView", 8);
    UIView *progressView = FindViewByClassName(rootView, @"PGProgressIndicator", 8);
    UIView *backdropView = FindViewByClassName(rootView, @"PGCABackdropLayerView", 8);
    UIView *dimmingView = FindViewByClassName(rootView, @"PGDimmingView", 8);
    UIView *stashView = FindViewByClassName(rootView, @"PGStashView", 8);

    if (!layoutView || !progressView || !backdropView || !dimmingView || !stashView) return NO;
    if (!ViewIsHiddenOrTransparent(progressView)) return NO;
    if (!ViewIsHiddenOrTransparent(backdropView)) return NO;
    if (!ViewIsHiddenOrTransparent(dimmingView)) return NO;
    if (!stashView.hidden) return NO;

    NSUInteger hiddenButtons = CountDirectSubviewClass(layoutView, @"PGButtonView", YES);
    NSUInteger visibleButtons = CountDirectSubviewClass(layoutView, @"PGButtonView", NO);
    return hiddenButtons >= 3 && visibleButtons <= 2;
}

static DoubaoPiPIdentity IdentityFromPiPController(id pipCtrl) {
    DoubaoPiPIdentity identity = IdentityFromPiPControllerLocal(pipCtrl);
    if (identity != DoubaoPiPIdentityUnknown) return identity;

    return IdentityFromPegasusApp(pipCtrl);
}

static BOOL HasMultipleActivePiPWindows(UIWindow *candidate, BOOL forceRefresh) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!forceRefresh && sLastPiPWindowCountCheckTime > 0 && now - sLastPiPWindowCountCheckTime < kPiPWindowCountCacheInterval) {
        return sLastHasMultipleActivePiPWindows;
    }

    NSUInteger count = 0;
    BOOL hasMultiple = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *allWindows = [(id)[UIApplication sharedApplication] performSelector:NSSelectorFromString(@"windows")];
#pragma clang diagnostic pop
    for (UIWindow *w in allWindows) {
        if (w == candidate || IsVisiblePiPWindow(w)) {
            count++;
            if (count >= 2) {
                hasMultiple = YES;
                break;
            }
        }
    }

    sLastPiPWindowCountCheckTime = now;
    sLastHasMultipleActivePiPWindows = hasMultiple;
    return hasMultiple;
}

static BOOL IsDoubaoPiPWindowWithRefresh(UIWindow *window, BOOL forceRefresh) {
    if (!window) return NO;
    if (!IsPiPWindow(window)) return NO;

    UIViewController *rvc = window.rootViewController;
    if (!rvc) return NO;

    id pipCtrl = SafeKVC(rvc, @"_pipController");
    DoubaoPiPIdentity identity = IdentityFromPiPController(pipCtrl);

    if (!HasMultipleActivePiPWindows(window, forceRefresh)) {
        if (identity == DoubaoPiPIdentityDoubao) return YES;
        if (identity == DoubaoPiPIdentityNonDoubao) return NO;
    } else {
        return IsLikelyDoubaoPiPWindowByViewTree(window);
    }

    return IsLikelyDoubaoPiPWindowByViewTree(window);
}

static BOOL IsDoubaoPiPWindow(UIWindow *window) {
    return IsDoubaoPiPWindowWithRefresh(window, NO);
}

static BOOL ObjectLooksLikePiPStashTarget(id object) {
    NSString *className = SafeClassName(object);
    return [className containsString:@"PIP"] || [className containsString:@"PictureInPicture"] || [className hasPrefix:@"PG"];
}

static BOOL StashObjectIfSupported(id object) {
    if (!object || !ObjectLooksLikePiPStashTarget(object)) return NO;

    SEL animatedSelector = NSSelectorFromString(@"setStashed:animated:");
    SEL simpleSelector = NSSelectorFromString(@"setStashed:");

    @try {
        if ([object respondsToSelector:animatedSelector]) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(object, animatedSelector, YES, YES);
            return YES;
        }

        if ([object respondsToSelector:simpleSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(object, simpleSelector, YES);
            return YES;
        }
    } @catch (NSException *e) {
        return NO;
    }

    return NO;
}

static BOOL StashViewControllerTree(UIViewController *viewController, NSUInteger maxDepth) {
    if (!viewController) return NO;
    if (StashObjectIfSupported(viewController)) return YES;
    if (maxDepth == 0) return NO;

    for (UIViewController *child in viewController.childViewControllers) {
        if (StashViewControllerTree(child, maxDepth - 1)) return YES;
    }
    return NO;
}

static BOOL StashDoubaoWindow(UIWindow *window) {
    UIViewController *rvc = window.rootViewController;
    if (!rvc) return NO;

    if (StashViewControllerTree(rvc, 4)) return YES;

    NSArray *keys = @[
        @"_pictureInPictureViewController",
        @"_pegasusPictureInPictureViewController",
        @"_pipViewController",
        @"_contentViewController"
    ];
    for (NSString *key in keys) {
        id object = SafeKVC(rvc, key);
        if ([object isKindOfClass:[UIViewController class]] && StashViewControllerTree(object, 3)) return YES;
        if (StashObjectIfSupported(object)) return YES;
    }
    return NO;
}

// ============================================================
// Part 1: idle timer fix & hide target PiP
// ============================================================

static BOOL IsTargetPiPController(id pipCtrl) {
    return IdentityFromPiPController(pipCtrl) == DoubaoPiPIdentityDoubao;
}

static void InvalidateIdleTimerForPiPWindow(UIWindow *window) {
    if (!window) return;
    UIViewController *rvc = window.rootViewController;
    if (!rvc) return;
    id pipCtrl = SafeKVC(rvc, @"_pipController");
    if (!pipCtrl || !IsTargetPiPController(pipCtrl)) return;

    @try {
        SEL invalidateSel = NSSelectorFromString(@"invalidateIdleTimerBehaviors");
        if ([pipCtrl respondsToSelector:invalidateSel]) {
            ((void (*)(id, SEL))objc_msgSend)(pipCtrl, invalidateSel);
            WriteLog(@"[IDLE] invalidateIdleTimerBehaviors ptr=%p", pipCtrl);
        }
    } @catch (NSException *e) {}
}

static void HideDoubaoWindow(UIWindow *window, NSString *reason) {
    if (!window || !IsVisiblePiPWindow(window)) return;

    BOOL forceRefresh = [reason isEqualToString:@"didMoveToWindow"] || [reason isEqualToString:@"setHidden"] || [reason isEqualToString:@"setAlpha"];
    if (HasMultipleActivePiPWindows(window, forceRefresh)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *allWindows = [(id)[UIApplication sharedApplication] performSelector:NSSelectorFromString(@"windows")];
#pragma clang diagnostic pop
        for (UIWindow *w in allWindows) {
            if (!IsVisiblePiPWindow(w)) continue;
            if (!IsDoubaoPiPWindow(w)) continue;

            BOOL stashed = StashDoubaoWindow(w);
            w.alpha = 0.0;
            w.userInteractionEnabled = NO;
            InvalidateIdleTimerForPiPWindow(w);
            WriteLog(@"[WINDOW] Hidden Doubao PiP ptr=%p reason=%@ stashed=%d", w, reason, stashed);
        }
        return;
    }

    if (!IsDoubaoPiPWindowWithRefresh(window, forceRefresh)) return;

    BOOL stashed = StashDoubaoWindow(window);
    window.alpha = 0.0;
    window.userInteractionEnabled = NO;
    InvalidateIdleTimerForPiPWindow(window);
    WriteLog(@"[WINDOW] Hidden Doubao PiP ptr=%p reason=%@ stashed=%d", window, reason, stashed);
}

static void HideDoubaoWindowForView(UIView *view, NSString *reason) {
    if (!view) return;
    HideDoubaoWindow(view.window, reason);
}

@interface SBPictureInPictureWindow : UIWindow
@end

%hook SBPictureInPictureWindow

- (void)didMoveToWindow {
    %orig;
    HideDoubaoWindow(self, @"didMoveToWindow");
}

- (void)layoutSubviews {
    %orig;
    HideDoubaoWindow(self, @"layoutSubviews");
}

- (void)setAlpha:(CGFloat)alpha {
    if (alpha > 0.01 && IsDoubaoPiPWindowWithRefresh(self, YES)) {
        StashDoubaoWindow(self);
        InvalidateIdleTimerForPiPWindow(self);
        %orig(0.0);
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!hidden) {
        HideDoubaoWindow(self, @"setHidden");
    }
}

%end

%hook SBPIPContainerViewController

- (void)viewDidLayoutSubviews {
    %orig;
    HideDoubaoWindowForView(((UIViewController *)self).view, @"containerViewDidLayout");
}

%end

%hook PGHitTestExtendableView

- (void)layoutSubviews {
    %orig;
    HideDoubaoWindowForView((UIView *)self, @"hitTestLayout");
}

%end

%hook PGControlsView

- (void)layoutSubviews {
    %orig;
    HideDoubaoWindowForView((UIView *)self, @"controlsLayout");
}

%end

%hook PGLayoutContainerView

- (void)layoutSubviews {
    %orig;
    HideDoubaoWindowForView((UIView *)self, @"layoutContainerLayout");
}

%end

// idle timer hook: stop target PiP from acquiring sleep lock + release stale assertions
%hook SBPIPController

- (void)_acquireIdleTimerDisableAssertion {
    if (IsTargetPiPController(self)) return;
    %orig;
}

- (BOOL)preventsIdleTimer {
    if (IsTargetPiPController(self)) return NO;
    return %orig;
}

- (BOOL)_preventsIdleTimer {
    if (IsTargetPiPController(self)) return NO;
    return %orig;
}

%end

// ============================================================
// Part 2: Auto-close doubao/wetype split-screen popup
//
// Paid TrollOpen behavior (verified):
//   Wetype renders briefly, then the popup auto-dismisses.
//   The process is NOT killed — only the popup window disappears.
//
// Multi-strategy close (tried in order):
//   1. UIWindow iteration: find target windows → hide (alpha=0, hidden=YES)
//   2. FBSceneManager: find target scene → invalidate
//   3. SBMainWorkspace: externalApplicationSceneHandles → destroyScene
// ============================================================

static const NSTimeInterval kAutoCloseDelay = 2.0;

static BOOL IsAutoCloseBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    return [bundleID isEqualToString:@"com.bytedance.ios.doubaoime"] ||
           [bundleID isEqualToString:@"com.bytedance.ios.doubaoime.keyboard"] ||
           [bundleID isEqualToString:@"com.tencent.wetype"] ||
           [bundleID isEqualToString:@"com.tencent.wetype.keyboard"];
}

// Extract bundleIdentifier from an FBScene via identity or clientProcess
static NSString *BundleIDFromFBScene(id scene) {
    if (!scene) return nil;
    @try {
        id identity = [scene valueForKey:@"identity"];
        if (identity) {
            NSString *bid = [identity valueForKey:@"bundleIdentifier"];
            if (bid) return bid;
            bid = [identity valueForKey:@"_bundleIdentifier"];
            if (bid) return bid;
        }
        id cp = [scene valueForKey:@"clientProcess"];
        if (cp) {
            NSString *bid = [cp valueForKey:@"bundleIdentifier"];
            if (bid) return bid;
            bid = [cp valueForKey:@"_bundleIdentifier"];
            if (bid) return bid;
        }
        id ci = [scene valueForKey:@"clientIdentity"];
        if (ci) {
            NSString *bid = [ci valueForKey:@"bundleIdentifier"];
            if (bid) return bid;
        }
    } @catch (NSException *e) {}
    return nil;
}

// Strategy 1: Hide any UIWindow belonging to the target bundle
static BOOL TryHideWindowsForBundleID(NSString *bundleID) {
    @try {
        Class appClass = objc_getClass("UIApplication");
        id app = [appClass performSelector:@selector(sharedApplication)];
        NSArray *allWindows = [app valueForKey:@"windows"];

        BOOL found = NO;
        for (UIWindow *window in allWindows) {
            if (window.hidden || window.alpha < 0.01) continue;

            @try {
                id windowScene = [window valueForKey:@"windowScene"];
                if (!windowScene) windowScene = [window valueForKey:@"_windowScene"];

                if (windowScene) {
                    id fbScene = [windowScene valueForKey:@"_scene"];
                    if (!fbScene) fbScene = [windowScene valueForKey:@"scene"];

                    NSString *winBundleID = BundleIDFromFBScene(fbScene);
                    if (![winBundleID isEqualToString:bundleID]) continue;

                    WriteLog(@"[AUTOCLOSE] Hiding target window ptr=%p class=%@", window, SafeClassName(window));
                    window.hidden = YES;
                    window.alpha = 0.0;
                    window.userInteractionEnabled = NO;
                    found = YES;
                }
            } @catch (NSException *e) {}
        }
        return found;
    } @catch (NSException *e) {}
    return NO;
}

// Strategy 2: FBSceneManager -> invalidate target scene
static BOOL TryCloseViaFBSceneManager(NSString *bundleID) {
    @try {
        Class mgrClass = objc_getClass("FBSceneManager");
        if (!mgrClass) return NO;
        id mgr = [mgrClass performSelector:@selector(sharedInstance)];
        if (!mgr) return NO;

        id scenes = [mgr valueForKey:@"_scenes"];
        if (!scenes) scenes = [mgr valueForKey:@"scenes"];
        if (![scenes respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return NO;

        for (id scene in scenes) {
            @try {
                NSString *bid = BundleIDFromFBScene(scene);
                if (![bid isEqualToString:bundleID]) continue;

                WriteLog(@"[AUTOCLOSE] Found target FBScene, invalidating...");

                SEL invalidateSel = NSSelectorFromString(@"invalidate");
                if ([scene respondsToSelector:invalidateSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(scene, invalidateSel);
                    return YES;
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return NO;
}

// Strategy 3: externalApplicationSceneHandles -> destroySceneWithTransitionContext
static BOOL TryDestroySceneForBundleID(NSString *bundleID) {
    @try {
        Class workspaceClass = objc_getClass("SBMainWorkspace");
        if (!workspaceClass) return NO;
        id workspace = [workspaceClass performSelector:@selector(sharedInstance)];
        if (!workspace) return NO;

        id sceneHandles = [workspace valueForKey:@"externalApplicationSceneHandles"];
        if (![sceneHandles respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return NO;

        for (id handle in sceneHandles) {
            @try {
                id app = [handle valueForKey:@"application"];
                if (!app) app = [handle valueForKey:@"_application"];

                NSString *handleBundleID = [app valueForKey:@"bundleIdentifier"];
                if (!handleBundleID) handleBundleID = [app valueForKey:@"_bundleIdentifier"];

                if (![handleBundleID isEqualToString:bundleID]) continue;

                SEL destroySel = NSSelectorFromString(@"destroySceneWithTransitionContext:");
                if ([handle respondsToSelector:destroySel]) {
                    WriteLog(@"[AUTOCLOSE] destroySceneWithTransitionContext for %@", bundleID);
                    ((void (*)(id, SEL, id))objc_msgSend)(handle, destroySel, nil);
                    return YES;
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return NO;
}

static void ClosePopupForBundleID(NSString *bundleID) {
    WriteLog(@"[AUTOCLOSE] Attempting to close popup for bundleID=%@", bundleID);

    if (TryHideWindowsForBundleID(bundleID)) return;
    if (TryCloseViaFBSceneManager(bundleID)) return;
    TryDestroySceneForBundleID(bundleID);
}

// ============================================================
// Detection hooks for TrollOpen split-screen + standard launches
// ============================================================

static void ScheduleCloseForBundleID(NSString *bundleID) {
    NSString *capturedBundleID = [bundleID copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAutoCloseDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ClosePopupForBundleID(capturedBundleID);
    });
}

// Hook 1: SBApplication._setFrontmost: - fires for ANY app becoming foreground
%hook SBApplication

- (void)_setFrontmost:(BOOL)frontmost {
    %orig;
    if (!frontmost) return;

    NSString *bid = nil;
    @try { bid = ((id (*)(id, SEL, id))objc_msgSend)(self, @selector(valueForKey:), @"bundleIdentifier"); } @catch (NSException *e) {}
    if (!bid) @try { bid = ((id (*)(id, SEL, id))objc_msgSend)(self, @selector(valueForKey:), @"_bundleIdentifier"); } @catch (NSException *e) {}

    WriteLog(@"[AUTOCLOSE] SBApplication _setFrontmost:YES bundleID=%@", bid ?: @"(nil)");
    if (IsAutoCloseBundleID(bid)) {
        ScheduleCloseForBundleID(bid);
    }
}

%end

// Hook 2: FBScene creation - catches TrollOpen scene setup
%hook FBScene

- (id)initWithIdentifier:(id)sceneID settings:(id)settings clientProvider:(id)provider {
    id result = %orig;
    NSString *bid = BundleIDFromFBScene(result);
    WriteLog(@"[AUTOCLOSE] FBScene init bundleID=%@ sceneID=%@", bid ?: @"(nil)", sceneID);
    if (IsAutoCloseBundleID(bid)) {
        ScheduleCloseForBundleID(bid);
    }
    return result;
}

%end

// Hook 3: SBMainWorkspace - standard launch path fallback
%hook SBMainWorkspace

- (void)_handleOpenApplicationRequest:(id)request options:(id)options activationSettings:(id)settings origin:(id)origin withResult:(id)result {
    NSString *bundleID = nil;
    @try {
        if ([request respondsToSelector:@selector(bundleIdentifier)]) {
            bundleID = [request performSelector:@selector(bundleIdentifier)];
        }
    } @catch (NSException *e) {
        @try { bundleID = [request valueForKey:@"bundleIdentifier"]; } @catch (NSException *e2) {}
    }

    %orig;

    if (IsAutoCloseBundleID(bundleID)) {
        WriteLog(@"[AUTOCLOSE] SBMainWorkspace open-app detected: %@", bundleID);
        ScheduleCloseForBundleID(bundleID);
    }
}

%end

%ctor {
    WriteLog(@"[INIT] HideDoubaoPiP v1.0.4 - wetype support + idle timer fix + autoclose");
}
