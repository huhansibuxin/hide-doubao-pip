#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL IsDoubaoBundleID(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value isEqualToString:@"com.bytedance.ios.doubaoime"];
}

typedef NS_ENUM(NSInteger, DoubaoPiPIdentity) {
    DoubaoPiPIdentityUnknown = 0,
    DoubaoPiPIdentityDoubao,
    DoubaoPiPIdentityNonDoubao,
};

static DoubaoPiPIdentity IdentityFromBundleID(id value) {
    if (![value isKindOfClass:[NSString class]]) return DoubaoPiPIdentityUnknown;
    NSString *bundleID = (NSString *)value;
    if (bundleID.length == 0) return DoubaoPiPIdentityUnknown;
    return IsDoubaoBundleID(bundleID) ? DoubaoPiPIdentityDoubao : DoubaoPiPIdentityNonDoubao;
}

static id SafeKVC(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try { return [object valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static NSString *SafeClassName(id object) {
    if (!object) return nil;
    @try { return NSStringFromClass(object_getClass(object)); }
    @catch (NSException *e) { return nil; }
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
    id bundleID = SafeKVC(activeApp, @"_bundleIdentifier");
    return IdentityFromBundleID(bundleID);
}

static DoubaoPiPIdentity IdentityFromPiPController(id pipCtrl) {
    if (!pipCtrl) return DoubaoPiPIdentityUnknown;
    NSArray *bundleKeys = @[@"_bundleIDForAppAnimatingPIPStartInBackground", @"_bundleIDForAppRecentlyStoppingPIP"];
    for (NSString *key in bundleKeys) {
        id val = SafeKVC(pipCtrl, key);
        DoubaoPiPIdentity identity = IdentityFromBundleID(val);
        if (identity != DoubaoPiPIdentityUnknown) return identity;
    }
    NSArray *processKeys = @[@"_pipProcess", @"_applicationProcess"];
    for (NSString *key in processKeys) {
        id proc = SafeKVC(pipCtrl, key);
        DoubaoPiPIdentity identity = IdentityFromProcess(proc);
        if (identity != DoubaoPiPIdentityUnknown) return identity;
    }
    return IdentityFromPegasusApp(pipCtrl);
}

static BOOL IsDoubaoPiPController(id pipCtrl) {
    return IdentityFromPiPController(pipCtrl) == DoubaoPiPIdentityDoubao;
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
        if ([SafeClassName(subview) isEqualToString:className] && subview.hidden == hidden) count++;
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

static BOOL IsDoubaoPiPWindow(UIWindow *window) {
    if (!window) return NO;
    if (![SafeClassName(window) isEqualToString:@"SBPictureInPictureWindow"]) return NO;
    UIViewController *rvc = window.rootViewController;
    if (!rvc) return NO;
    id pipCtrl = SafeKVC(rvc, @"_pipController");
    DoubaoPiPIdentity identity = IdentityFromPiPController(pipCtrl);
    if (identity == DoubaoPiPIdentityDoubao) return YES;
    if (identity == DoubaoPiPIdentityNonDoubao) return NO;
    return IsLikelyDoubaoPiPWindowByViewTree(window);
}

static void HideDoubaoWindow(UIWindow *window) {
    if (!window || !IsDoubaoPiPWindow(window)) return;
    window.alpha = 0.0;
    window.userInteractionEnabled = NO;
}

static void HideDoubaoWindowForView(UIView *view) {
    if (!view) return;
    HideDoubaoWindow(view.window);
}

@interface SBPictureInPictureWindow : UIWindow @end
@interface SBPIPController : NSObject @end

%hook SBPictureInPictureWindow
- (void)didMoveToWindow { %orig; HideDoubaoWindow(self); }
- (void)layoutSubviews { %orig; HideDoubaoWindow(self); }
- (void)setAlpha:(CGFloat)alpha {
    if (alpha > 0.0 && IsDoubaoPiPWindow(self)) { %orig(0.0); return; }
    %orig;
}
- (void)setHidden:(BOOL)hidden { %orig; if (!hidden) HideDoubaoWindow(self); }
%end

%hook SBPIPContainerViewController
- (void)viewDidLayoutSubviews { %orig; HideDoubaoWindowForView(((UIViewController *)self).view); }
%end

%hook PGHitTestExtendableView
- (void)layoutSubviews { %orig; HideDoubaoWindowForView((UIView *)self); }
%end

%hook PGControlsView
- (void)layoutSubviews { %orig; HideDoubaoWindowForView((UIView *)self); }
%end

%hook PGLayoutContainerView
- (void)layoutSubviews { %orig; HideDoubaoWindowForView((UIView *)self); }
%end

%hook SBPIPController
- (void)invalidateIdleTimerBehaviors {
    if (IsDoubaoPiPController(self)) return;
    %orig;
}
%end