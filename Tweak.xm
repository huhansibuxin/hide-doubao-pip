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

// Forward declaration — BundleIDOfWindowOwner below uses SafeKVC, which is
// defined further down.
static id SafeKVC(id object, NSString *key);

// The PiP window is created/hosted by SpringBoard but represents content owned by
// the SOURCE app (WeChat for a video PiP, the IME for the voice strip). The real
// owning process is reachable through the window's UIScene -> FBScene ->
// clientProcess, which carries the genuine source bundle INDEPENDENTLY of any
// reused/stale PiP controller. This is the reliable, early differentiator we need
// — unlike _pipController.bundleID, it does not go stale when SpringBoard recycles
// a single PiP controller across apps.
static NSString *BundleIDOfWindowOwner(UIWindow *window) {
    @try {
        id ws = SafeKVC(window, @"windowScene");
        if (ws) {
            id scene = SafeKVC(ws, @"scene");
            if (scene) {
                id client = SafeKVC(scene, @"clientProcess");
                if (!client) client = SafeKVC(scene, @"_clientProcess");
                NSString *b = SafeKVC(client, @"bundleIdentifier");
                if (b) return b;
                b = SafeKVC(scene, @"boundApplicationBundleIdentifier");
                if (!b) b = SafeKVC(scene, @"_boundApplicationBundleIdentifier");
                if (b) return b;
            }
        }
        // Fallback: some windows expose the FBScene directly.
        id scene2 = SafeKVC(window, @"_scene");
        if (scene2) {
            id client = SafeKVC(scene2, @"clientProcess");
            if (!client) client = SafeKVC(scene2, @"_clientProcess");
            NSString *b = SafeKVC(client, @"bundleIdentifier");
            if (b) return b;
        }
    } @catch (NSException *e) {}
    return nil;
}

static DoubaoPiPIdentity IdentityFromWindowOwner(UIWindow *window) {
    NSString *bundle = BundleIDOfWindowOwner(window);
    if (!bundle) return DoubaoPiPIdentityUnknown;
    if (IsTargetBundleID(bundle)) return DoubaoPiPIdentityDoubao;
    // SpringBoard is the neutral host of PiP windows — treat it as unknown rather
    // than a definitive non-target, so we fall through to the controller identity.
    if ([bundle isEqualToString:@"com.apple.springboard"]) return DoubaoPiPIdentityUnknown;
    return DoubaoPiPIdentityNonDoubao;
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
            [cls containsString:@"WebRTC"]) {
            return YES;
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

// Recursively collect unique SpringBoard-rendered subview class names.
static void CollectViewClassNames(UIView *view, NSUInteger depth, NSMutableSet<NSString *> *classNames) {
    if (!view || depth > 20) return;
    NSString *cls = SafeClassName(view);
    if (cls) [classNames addObject:cls];
    for (UIView *sub in view.subviews) {
        CollectViewClassNames(sub, depth + 1, classNames);
    }
}

// Voice/dictation chrome keywords. The IME voice strip renders dictation UI
// (mic, waveform, keyboard, language) in SpringBoard-local chrome; a video PiP
// never contains these. Used as the PRIMARY hide signal so a video PiP is never
// stashed just because its PiP controller still carries a stale IME bundle.
static BOOL WindowHasVoiceChrome(UIWindow *window) {
    UIView *rootView = window.rootViewController.view;
    if (!rootView) return NO;
    NSMutableSet<NSString *> *classNames = [NSMutableSet set];
    CollectViewClassNames(rootView, 0, classNames);
    NSArray<NSString *> *voiceKeywords = @[
        @"Dictation", @"Voice", @"Waveform", @"Wavy", @"Mic", @"Speech",
        @"Siri", @"Dictate", @"Transcribe", @"AudioInput", @"Talk"
    ];
    for (NSString *cls in classNames) {
        for (NSString *kw in voiceKeywords) {
            if ([cls containsString:kw]) return YES;
        }
    }
    return NO;
}

// Recursively collect unique layer class names + capture CALayerHost/CARemoteLayer
// contextIds (the cross-process video/IME content handle — its contextId maps to
// the source app's CAContext, the real owner we are hunting for).
static void CollectLayerNamesForDiag(CALayer *layer, NSUInteger depth, NSMutableSet<NSString *> *layerNames, NSMutableArray<NSString *> *ctxIds) {
    if (!layer || depth > 14) return;
    NSString *cls = SafeClassName(layer);
    if (cls) [layerNames addObject:cls];
    if ([cls isEqualToString:@"CALayerHost"] || [cls isEqualToString:@"CARemoteLayer"] || [cls isEqualToString:@"_UILayerHost"]) {
        id cid = SafeKVC(layer, @"contextId");
        if (cid) [ctxIds addObject:[NSString stringWithFormat:@"%@:%@", cls, cid]];
    }
    for (CALayer *sub in layer.sublayers) {
        CollectLayerNamesForDiag(sub, depth + 1, layerNames, ctxIds);
    }
}

// Enumerate every KVC-visible property (best-effort) of an object — used by the
// diagnostic to discover the real owner/process field names. Capped to stay small.
static NSString *EnumerateKeys(id object) {
    if (!object) return @"<nil>";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(object_getClass(object), &count);
    for (unsigned int i = 0; i < count && parts.count < 40; i++) {
        NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
        @try {
            id v = [object valueForKey:name];
            if (v) [parts addObject:[NSString stringWithFormat:@"%@=%@", name, v]];
        } @catch (NSException *e) {}
    }
    free(props);
    if (parts.count == 0) return [NSString stringWithFormat:@"<no-props:%@>", SafeClassName(object)];
    return [parts componentsJoinedByString:@"; "];
}

// Comprehensive one-time dump of everything reachable about a PiP window, so we can
// pinpoint the exact field exposing the REAL owning app (WeChat vs IME) and the
// view/layer classes that differ between the voice strip and a video PiP.
static void DiagnosePiPWindow(UIWindow *window) {
    uintptr_t p = (uintptr_t)window;
    NSString *key = [NSString stringWithFormat:@"%llu", (unsigned long long)p];
    if ([sDiagnosedPtrs containsObject:key]) return;
    [sDiagnosedPtrs addObject:key];

    UIViewController *rvc = window.rootViewController;
    id pipCtrl = SafeKVC(rvc, @"_pipController");
    id ws = SafeKVC(window, @"windowScene");
    id scene = ws ? SafeKVC(ws, @"scene") : nil;
    id client = scene ? SafeKVC(scene, @"clientProcess") : nil;
    if (!client) client = scene ? SafeKVC(scene, @"_clientProcess") : nil;

    NSMutableString *info = [NSMutableString string];
    [info appendFormat:@"\n[DIAG-START] ptr=%p\n", window];
    [info appendFormat:@"  windowClass=%@ rvcClass=%@ pipCtrlClass=%@ tag=%ld\n",
        SafeClassName(window), SafeClassName(rvc), SafeClassName(pipCtrl), (long)window.tag];
    [info appendFormat:@"  windowSceneClass=%@ sceneClass=%@ clientProcessClass=%@\n",
        SafeClassName(ws), SafeClassName(scene), SafeClassName(client)];
    [info appendFormat:@"  client.bundleIdentifier=%@ client.bundleID=%@ client.pid=%@\n",
        SafeKVC(client, @"bundleIdentifier"), SafeKVC(client, @"bundleID"), SafeKVC(client, @"pid")];
    [info appendFormat:@"  client.props=%@\n", EnumerateKeys(client)];
    [info appendFormat:@"  scene.props=%@\n", EnumerateKeys(scene)];
    [info appendFormat:@"  pipCtrl.props=%@\n", EnumerateKeys(pipCtrl)];

    UIView *rootView = rvc.view;
    NSMutableSet<NSString *> *viewClasses = [NSMutableSet set];
    if (rootView) CollectViewClassNames(rootView, 0, viewClasses);
    NSArray *sortedViews = [[viewClasses allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [info appendFormat:@"  viewClasses(%lu)=%@\n", (unsigned long)sortedViews.count, sortedViews];

    NSMutableSet<NSString *> *layerClasses = [NSMutableSet set];
    NSMutableArray<NSString *> *ctxIds = [NSMutableArray array];
    if (rootView) CollectLayerNamesForDiag(rootView.layer, 0, layerClasses, ctxIds);
    NSArray *sortedLayers = [[layerClasses allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [info appendFormat:@"  layerClasses(%lu)=%@\n", (unsigned long)sortedLayers.count, sortedLayers];
    [info appendFormat:@"  layerHostContextIds=%@\n", ctxIds];
    [info appendFormat:@"  hasVideoContent=%d hasVoiceChrome=%d viewTreeSignal=%d\n",
        WindowHasVideoContent(window), WindowHasVoiceChrome(window), IsLikelyDoubaoPiPWindowByViewTree(window)];
    [info appendFormat:@"[DIAG-END] ptr=%p\n", window];
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

    // 0) Dump everything once so we can build the final discriminator from real data.
    DiagnosePiPWindow(window);

    // 1) Real video playback layers (AVPlayerLayer, etc.) -> never strip, even on
    //    first appearance. This already excludes most genuine video PiPs.
    if (WindowHasVideoContent(window)) {
        [sAllowlistedWindows addObject:ptrKey];
        return NO;
    }
    if ([sAllowlistedWindows containsObject:ptrKey] || [sNeverHideWindows containsObject:ptrKey]) {
        return NO;
    }

    // 2) A real NON-IME controller (WeChat…) means a genuine video PiP -> never hide.
    //    (On first appearance the controller may still carry a stale IME bundle, so
    //    this only catches the settled case; step 4 covers the ambiguous one.)
    id pipCtrl = SafeKVC(rvc, @"_pipController");
    DoubaoPiPIdentity ctrlIdentity = IdentityFromPiPController(pipCtrl);
    if (ctrlIdentity == DoubaoPiPIdentityNonDoubao) {
        [sAllowlistedWindows addObject:ptrKey];
        return NO;
    }

    // 3) Window owner (source app) if reachable through the scene/client-process.
    DoubaoPiPIdentity ownerIdentity = IdentityFromWindowOwner(window);
    if (ownerIdentity == DoubaoPiPIdentityNonDoubao) {
        [sAllowlistedWindows addObject:ptrKey];
        return NO;
    }

    // 4) PRIMARY hide signal: dictation/voice chrome present in SpringBoard's own
    //    view tree. A video PiP never contains these classes, and the chrome is
    //    created synchronously with the window, so this works on FIRST appearance
    //    (no timing dependence on the remote video layer or a stale controller).
    if (WindowHasVoiceChrome(window)) {
        WriteLog(@"[IDENTIFY] ptr=%p voiceChrome -> HIDE (voice strip)", window);
        return YES;
    }

    // 5) Both identities inconclusive AND no voice chrome. Do NOT hide on first
    //    appearance. Defer + re-check: the controller/owner may settle, the voice
    //    chrome may appear, or a video layer may attach. Cap at 2 re-checks; if
    //    still ambiguous, give up (never hide) so a video PiP is never stashed.
    if (ownerIdentity == DoubaoPiPIdentityDoubao) {
        WriteLog(@"[IDENTIFY] ptr=%p owner=Doubao but no voiceChrome -> DEFER (suspect stale video)", window);
    } else {
        WriteLog(@"[IDENTIFY] ptr=%p owner=Unknown no voiceChrome -> DEFER", window);
    }
    NSNumber *c = sDeferCount[ptrKey];
    NSInteger count = c ? c.integerValue : 0;
    if (count >= 2) {
        [sNeverHideWindows addObject:ptrKey];
        WriteLog(@"[IDENTIFY] ptr=%p no-signal after defers -> EXCLUDE (protect video)", window);
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
            WriteLog(@"[WINDOW] Hidden Doubao PiP ptr=%p reason=%@ stashed=%d owner=%@", w, reason, stashed, BundleIDOfWindowOwner(w));
        }
        return;
    }

    if (!IsDoubaoPiPWindowWithRefresh(window, forceRefresh)) return;

    BOOL stashed = StashDoubaoWindow(window);
    window.alpha = 0.0;
    window.userInteractionEnabled = NO;
    InvalidateIdleTimerForPiPWindow(window);
    WriteLog(@"[WINDOW] Hidden Doubao PiP ptr=%p reason=%@ stashed=%d owner=%@", window, reason, stashed, BundleIDOfWindowOwner(window));
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
    WriteLog(@"[INIT] HideDoubaoPiP v1.0.12 - voice-chrome primary signal + full introspection diag");
}
