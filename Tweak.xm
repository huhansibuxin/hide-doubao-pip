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

// Runtime state for the deferred-verification scheme (see IsDoubaoPiPWindowWithRefresh).
// A window is keyed by its pointer value (stringified). We deliberately trade a
// tiny risk of stale-pointer collision for simplicity — the sets are pruned on
// use and the worst case is a one-time misclassification, never a crash.
static NSMutableSet *sAllowlistedWindows = nil;   // proven video / non-target -> never hide
static NSMutableSet *sNeverHideWindows = nil;     // gave up after defers -> never hide
static NSMutableSet *sScheduledDefers = nil;      // ptrs with a pending re-check timer
static NSMutableDictionary *sDeferCount = nil;    // ptr -> number of defers so far
static NSMutableSet *sDiagnosedPtrs = nil;        // ptrs we already dumped diagnostics for

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

    // Broadened process keys: _application / _pipApplication are the most reliable
    // source-app handles on SBPIPController / PGPictureInPictureController and are
    // usually populated with the REAL owning app (WeChat, etc.) even when the
    // legacy bundle-ID ivars are still empty during a controller swap.
    NSArray *processKeys = @[@"_pipProcess", @"_applicationProcess", @"_application", @"_pipApplication"];
    for (NSString *key in processKeys) {
        DoubaoPiPIdentity identity = IdentityFromProcess(SafeKVC(pipCtrl, key));
        if (identity != DoubaoPiPIdentityUnknown) return identity;
    }

    // contentViewController's owning application (SBApplication) if present.
    id cv = SafeKVC(pipCtrl, @"_contentViewController");
    if (cv) {
        DoubaoPiPIdentity identity = IdentityFromProcess(SafeKVC(cv, @"_application"));
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

// Recursively scan the layer tree for video playback layers.
// A real video PiP (WeChat, Bilibili, etc.) will have AVPlayerLayer,
// AVSampleBufferDisplayLayer, or similar — the voice strip never does.
// Implemented as a plain C function (not a recursive block) to avoid
// -Werror,-Wuninitialized and -Werror,-Warc-retain-cycles.
static void CollectVideoLayerNames(CALayer *layer, NSUInteger depth, NSMutableArray<NSString *> *layerNames) {
    if (!layer || depth > 12) return;
    NSString *cls = SafeClassName(layer);
    if (cls && cls.length > 0) [layerNames addObject:cls];
    for (CALayer *sub in layer.sublayers) {
        CollectVideoLayerNames(sub, depth + 1, layerNames);
    }
}

static BOOL WindowHasVideoContent(UIWindow *window) {
    UIView *rootView = window.rootViewController.view;
    if (!rootView) return NO;

    NSMutableArray<NSString *> *layerNames = [NSMutableArray array];
    CollectVideoLayerNames(rootView.layer, 0, layerNames);

    for (NSString *cls in layerNames) {
        if ([cls containsString:@"AVPlayerLayer"] ||
            [cls containsString:@"AVSampleBufferDisplayLayer"] ||
            [cls containsString:@"AVVideoLayer"] ||
            [cls containsString:@"AVCaptureVideoPreviewLayer"] ||
            [cls containsString:@"CAMetalLayer"] ||
            [cls containsString:@"CAEAGLLayer"] ||
            [cls containsString:@"RTCVideo"] ||
            [cls containsString:@"WebRTC"] ||
            // Cross-process video: the source app renders in its own process and
            // SpringBoard only sees a hosted layer shell (CALayerHost on iOS 16,
            // formerly _UILayerHost / CARemoteLayer). This is the real, reliable
            // differentiator between a video PiP and the locally-rendered voice
            // strip — and it survives the stale-reused-controller identity problem.
            [cls containsString:@"CALayerHost"] ||
            [cls containsString:@"CARemoteLayer"] ||
            [cls containsString:@"UILayerHost"] ||
            [cls containsString:@"CAContext"]) {
            WriteLog(@"[VIDEO] Found remote/video layer %@ -> NOT voice strip", cls);
            return YES;
        }
    }

    // Debug: surface layer names that hint at video / remote-hosted content so
    // we can refine detection if a real video PiP still slips through.
    for (NSString *cls in layerNames) {
        if ([cls containsString:@"Video"] || [cls containsString:@"Player"] ||
            [cls containsString:@"Remote"] || [cls containsString:@"Host"] ||
            [cls containsString:@"Metal"] || [cls containsString:@"Context"] ||
            [cls containsString:@"Sample"] || [cls containsString:@"Capture"] ||
            [cls containsString:@"Preview"] || [cls containsString:@"EAGL"]) {
            WriteLog(@"[VIDEO-DEBUG] layer %@ present", cls);
        }
    }

    return NO;
}

static BOOL IsLikelyDoubaoPiPWindowByViewTree(UIWindow *window) {
    UIView *rootView = window.rootViewController.view;
    if (!rootView) return NO;

    // Hard exclusion: if the window has video playback layers it is a real
    // video PiP, never the voice strip.
    if (WindowHasVideoContent(window)) return NO;

    UIView *hitTestView = FindViewByClassName(rootView, @"PGHitTestExtendableView", 8);
    if (!hitTestView) return NO;

    // Size check is now a soft signal, not a hard gate — the large unstashed
    // voice window exceeds the old bounds but still shares the same PG* skeleton.
    CGRect hitFrame = hitTestView.frame;
    CGFloat w = CGRectGetWidth(hitFrame);
    CGFloat h = CGRectGetHeight(hitFrame);
    if (w < 80.0 || h < 40.0) return NO;  // absurdly small → not our target

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

// Forward declaration — ScheduleDeferredVerification schedules a re-check that
// calls back into HideDoubaoWindow, which is defined further below.
static void HideDoubaoWindow(UIWindow *window, NSString *reason);

static UIWindow *FindLivePiPWindowByPointer(uintptr_t p) {
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *allWindows = [(id)[UIApplication sharedApplication] performSelector:NSSelectorFromString(@"windows")];
#pragma clang diagnostic pop
        for (UIWindow *w in allWindows) {
            if ((uintptr_t)w == p && IsPiPWindow(w)) return w;
        }
    } @catch (NSException *e) {}
    return nil;
}

// One-time diagnostic dump of every source-app handle we can reach, so we can
// pinpoint the exact field that exposes WeChat's bundle (vs the IME's) if a
// video PiP still slips through. Only logged once per window pointer.
static void DiagnosePiPWindow(UIWindow *window) {
    uintptr_t p = (uintptr_t)window;
    NSString *key = [NSString stringWithFormat:@"%llu", (unsigned long long)p];
    if ([sDiagnosedPtrs containsObject:key]) return;
    [sDiagnosedPtrs addObject:key];

    UIViewController *rvc = window.rootViewController;
    id pipCtrl = SafeKVC(rvc, @"_pipController");
    NSMutableString *info = [NSMutableString stringWithFormat:
        @"[DIAG] ptr=%p rvc=%@ pipCtrl=%@ hasVideo=%d",
        window, SafeClassName(rvc), SafeClassName(pipCtrl), WindowHasVideoContent(window)];

    NSArray *keys = @[@"_bundleIDForAppAnimatingPIPStartInBackground",
                      @"_bundleIDForAppRecentlyStoppingPIP",
                      @"_pipProcess", @"_applicationProcess", @"_application", @"_pipApplication"];
    for (NSString *k in keys) {
        id v = SafeKVC(pipCtrl, k);
        if (v) [info appendFormat:@" %@=%@", k, v];
    }
    id cv = SafeKVC(pipCtrl, @"_contentViewController");
    if (cv) {
        [info appendFormat:@" cvClass=%@", SafeClassName(cv)];
        id cvApp = SafeKVC(cv, @"_application");
        if (cvApp) [info appendFormat:@" cvApp=%@", cvApp];
    }
    id adapter = SafeKVC(pipCtrl, @"_adapter");
    id pegasus = SafeKVC(adapter, @"_pegasusController");
    id pegasusApp = SafeKVC(pegasus, @"_activePictureInPictureApplication");
    if (pegasusApp) [info appendFormat:@" pegasusApp=%@", pegasusApp];
    WriteLog(@"%@", info);
}

// Defer the hide decision for an ambiguous (identity==Unknown) window. We do NOT
// hide on first appearance; instead we re-run the full check shortly, after the
// real bundle / CALayerHost has had time to settle. Caps at 2 re-checks; if it is
// still ambiguous we give up (never hide) so a freshly-spawned VIDEO PiP is never
// stashed just because its identity/video-layer wasn't ready yet.
static void ScheduleDeferredVerification(UIWindow *window) {
    uintptr_t p = (uintptr_t)window;
    NSString *key = [NSString stringWithFormat:@"%llu", (unsigned long long)p];
    if ([sScheduledDefers containsObject:key]) return;

    NSNumber *c = sDeferCount[key];
    NSInteger count = c ? c.integerValue : 0;
    [sScheduledDefers addObject:key];
    sDeferCount[key] = @(count + 1);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sScheduledDefers removeObject:key];
        UIWindow *target = FindLivePiPWindowByPointer(p);
        if (target) HideDoubaoWindow(target, @"deferredRecheck");
    });
}

static BOOL IsDoubaoPiPWindowWithRefresh(UIWindow *window, BOOL forceRefresh) {
    if (!window) return NO;
    if (!IsPiPWindow(window)) return NO;

    UIViewController *rvc = window.rootViewController;
    if (!rvc) return NO;
    (void)forceRefresh;

    NSString *ptrKey = [NSString stringWithFormat:@"%llu", (unsigned long long)(uintptr_t)window];

    // 1) HARD EXCLUSION FIRST: a window that renders remote-hosted / video content
    //    can never be the voice strip — regardless of what its (possibly STALE /
    //    REUSED) PiP controller bundle ID claims. WeChat video PiP shows its frames
    //    via a CALayerHost (cross-process layer) once the call connects; the voice
    //    strip renders locally and never has one. This is the reliable differentiator
    //    that survives the reused-controller identity problem.
    if (WindowHasVideoContent(window)) {
        [sAllowlistedWindows addObject:ptrKey];
        return NO;
    }

    // 2) Sticky allowlist / never-hide: once proven video, or given up on after
    //    defers, keep excluded even if a reused controller later reports a stale
    //    Doubao bundle.
    if ([sAllowlistedWindows containsObject:ptrKey] || [sNeverHideWindows containsObject:ptrKey]) {
        return NO;
    }

    id pipCtrl = SafeKVC(rvc, @"_pipController");
    DoubaoPiPIdentity identity = IdentityFromPiPController(pipCtrl);

    // 3) Positive exclusion: a real non-target app (WeChat video, Bilibili, ...)
    //    MUST never be hidden.
    if (identity == DoubaoPiPIdentityNonDoubao) {
        [sAllowlistedWindows addObject:ptrKey];
        return NO;
    }

    // 4) Positive inclusion: a window whose PiP controller genuinely belongs to
    //    the IME voice strip -> hide.
    if (identity == DoubaoPiPIdentityDoubao) {
        WriteLog(@"[IDENTIFY] ptr=%p identity=Doubao -> HIDE", window);
        return YES;
    }

    // 5) identity == Unknown: controller not yet associated. A freshly-spawned
    //    voice strip AND a freshly-spawned video PiP look identical here (shared
    //    PG* skeleton, no video layer yet, bundle not populated). Do NOT hide on
    //    first appearance. Defer a re-check so the real bundle / CALayerHost can
    //    settle, then decide. Cap the deferrals; if still ambiguous, give up
    //    (never hide) —宁可漏掉语音小窗，也绝不误杀视频悬浮窗.
    DiagnosePiPWindow(window);

    NSNumber *c = sDeferCount[ptrKey];
    NSInteger count = c ? c.integerValue : 0;
    if (count >= 2) {
        // Gave up after defers. If it truly matches the voice-strip shape, hide
        // it (assume voice strip); otherwise leave it alone.
        [sNeverHideWindows addObject:ptrKey];
        if (IsLikelyDoubaoPiPWindowByViewTree(window)) {
            WriteLog(@"[IDENTIFY] ptr=%p identity=Unknown after defers, viewTree=YES -> HIDE (voice-strip assumption)", window);
            return YES;
        }
        return NO;
    }

    ScheduleDeferredVerification(window);
    return NO;
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

%ctor {
    sAllowlistedWindows = [NSMutableSet set];
    sNeverHideWindows = [NSMutableSet set];
    sScheduledDefers = [NSMutableSet set];
    sDeferCount = [NSMutableDictionary dictionary];
    sDiagnosedPtrs = [NSMutableSet set];
    WriteLog(@"[INIT] HideDoubaoPiP v1.0.10 - CALayerHost detect + defer Unknown (never hide video on first appearance)");
}
