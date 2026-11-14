// CamProbe - alat diagnosa saja. Tidak mengubah apa pun di Camera.
// Merekam hierarki view Camera (frame, clip, mask, transform, videoGravity) ke /var/mobile/26Cam_probe.txt
// setiap kali tata letak berubah (ganti mode Photo / Square / Video, dll).

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static NSArray<NSString *> *ProbePaths(void) {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"tmp/26Cam_probe.txt"],
        [home stringByAppendingPathComponent:@"Documents/26Cam_probe.txt"],
        [home stringByAppendingPathComponent:@"Library/Caches/26Cam_probe.txt"],
        @"/var/mobile/Media/26Cam_probe.txt",
        @"/var/mobile/Library/Caches/26Cam_probe.txt",
        @"/var/mobile/26Cam_probe.txt",
        @"/var/tmp/26Cam_probe.txt"
    ];
}
static void ProbeAppend(NSString *text) {
    for (NSString *p in ProbePaths()) {
        @try {
            NSFileManager *fm = NSFileManager.defaultManager;
            if (![fm fileExistsAtPath:p]) {
                if (![@"" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]) continue;
            }
            if ([[fm attributesOfItemAtPath:p error:nil] fileSize] > 400 * 1024) continue;
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) continue;
            [fh seekToEndOfFile];
            [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (id e) {}
    }
}
static NSString *gLastSig = nil;
static BOOL gPending = NO;

static NSString *RectStr(CGRect r) {
    return [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static void DumpView(UIView *v, int depth, NSMutableString *out) {
    if (depth > 8) return;
    NSMutableString *ind = [NSMutableString string];
    for (int i = 0; i < depth; i++) [ind appendString:@"  "];

    CGRect inWin = CGRectZero;
    @try { inWin = [v convertRect:v.bounds toView:nil]; } @catch (id e) {}

    NSMutableString *flags = [NSMutableString string];
    if (v.clipsToBounds) [flags appendString:@" clips"];
    if (v.hidden) [flags appendString:@" HIDDEN"];
    if (v.alpha < 0.99) [flags appendFormat:@" a=%.2f", v.alpha];
    if (!CGAffineTransformIsIdentity(v.transform)) {
        CGAffineTransform t = v.transform;
        [flags appendFormat:@" xf=[%.3f %.3f %.3f %.3f tx=%.1f ty=%.1f]", t.a, t.b, t.c, t.d, t.tx, t.ty];
    }
    if (v.layer.mask) [flags appendFormat:@" MASK=%@ %@", NSStringFromClass([v.layer.mask class]), RectStr(v.layer.mask.frame)];
    if (v.layer.masksToBounds) [flags appendString:@" masksToBounds"];
    CGFloat bgA = 0;
    if (v.backgroundColor) [v.backgroundColor getRed:NULL green:NULL blue:NULL alpha:&bgA];
    if (bgA > 0.01) [flags appendFormat:@" bg=%.2f", bgA];
    if ([v.layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        [flags appendFormat:@" gravity=%@", ((AVCaptureVideoPreviewLayer *)v.layer).videoGravity];
    }
    [out appendFormat:@"%@%@ win=%@ frame=%@ bounds=%@%@\n", ind, NSStringFromClass([v class]),
        RectStr(inWin), RectStr(v.frame), RectStr(v.bounds), flags];

    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
            [out appendFormat:@"%@  [layer] AVCaptureVideoPreviewLayer frame=%@ gravity=%@ mask=%@\n", ind,
                RectStr(l.frame), ((AVCaptureVideoPreviewLayer *)l).videoGravity, l.mask ? @"YES" : @"no"];
        }
    }
    for (UIView *s in v.subviews) DumpView(s, depth + 1, out);
}

@interface CAMViewfinderViewController : UIViewController
@end


static void DumpCompact(UIView *v, int depth, NSMutableString *out) {
    if (depth > 7) return;
    CGRect w = CGRectZero;
    @try { w = [v convertRect:v.bounds toView:nil]; } @catch (id e) {}
    BOOL big = (w.size.width >= 90 && w.size.height >= 90);
    BOOL isPrev = [NSStringFromClass([v class]) containsString:@"Preview"];
    if (big || isPrev) {
        NSMutableString *f = [NSMutableString string];
        if (v.clipsToBounds) [f appendString:@" C"];
        if (v.hidden) [f appendString:@" H"];
        if (v.layer.mask) [f appendString:@" MASK"];
        if (!CGAffineTransformIsIdentity(v.transform)) [f appendFormat:@" xf(%.2f,%.2f)", v.transform.a, v.transform.d];
        if ([v.layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) [f appendFormat:@" %@", ((AVCaptureVideoPreviewLayer *)v.layer).videoGravity];
        NSString *name = [NSStringFromClass([v class]) stringByReplacingOccurrencesOfString:@"CAM" withString:@""];
        [out appendFormat:@"%*s%@ %.0f,%.0f %.0fx%.0f%@\n", depth, "", name, w.origin.x, w.origin.y, w.size.width, w.size.height, f];
    }
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
            [out appendFormat:@"%*s[PL] %.0f,%.0f %.0fx%.0f %@\n", depth, "", l.frame.origin.x, l.frame.origin.y, l.frame.size.width, l.frame.size.height, ((AVCaptureVideoPreviewLayer *)l).videoGravity];
        }
    }
    for (UIView *s in v.subviews) DumpCompact(s, depth + 1, out);
}

static UITextView *gOverlay = nil;
static void ShowOverlay(UIViewController *vc, NSString *text) {
    UIWindow *win = vc.view.window;
    if (!win) return;
    if (!gOverlay) {
        gOverlay = [[UITextView alloc] init];
        gOverlay.userInteractionEnabled = NO;
        gOverlay.editable = NO;
        gOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        gOverlay.textColor = [UIColor greenColor];
        gOverlay.font = [UIFont fontWithName:@"Menlo" size:6.5] ?: [UIFont systemFontOfSize:6.5];
        gOverlay.textContainerInset = UIEdgeInsetsMake(20, 2, 0, 2);
    }
    if (gOverlay.superview != win) [win addSubview:gOverlay];
    gOverlay.frame = win.bounds;
    [win bringSubviewToFront:gOverlay];
    gOverlay.text = text;
}

static void ProbeNow(UIViewController *vc) {
    @try {
        UIWindow *win = vc.view.window;
        NSMutableString *body = [NSMutableString string];
        [body appendFormat:@"screen=%@ scale=%.1f safeArea=%@\n", RectStr([UIScreen mainScreen].bounds),
            [UIScreen mainScreen].scale, NSStringFromUIEdgeInsets(win.safeAreaInsets)];
        for (NSString *k in @[@"_currentMode", @"_currentDevice", @"_currentGraphConfiguration", @"_currentAspectRatio", @"_aspectRatio", @"_previewViewFrame"]) {
            @try {
                id val = [vc valueForKey:k];
                if (val) [body appendFormat:@"%@ = %@\n", k, val];
            } @catch (id e) {}
        }
        [body appendString:@"--- view tree ---\n"];
        DumpView(vc.view, 0, body);

        NSMutableString *cmp = [NSMutableString stringWithFormat:@"screen %@ safe %@\n", RectStr([UIScreen mainScreen].bounds), NSStringFromUIEdgeInsets(win.safeAreaInsets)];
        DumpCompact(vc.view, 0, cmp);
        ShowOverlay(vc, cmp);
        if ([body isEqualToString:gLastSig]) return;
        gLastSig = [body copy];

        NSMutableString *entry = [NSMutableString string];
        [entry appendFormat:@"\n==================== t=%.2f ====================\n", CACurrentMediaTime()];
        [entry appendString:body];

        ProbeAppend(entry);
    } @catch (id e) {}
}

%hook CAMViewfinderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (gPending) return;
    gPending = YES;
    __weak UIViewController *weakSelf = (UIViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gPending = NO;
        UIViewController *vc = weakSelf;
        if (vc) ProbeNow(vc);
    });
}
%end

%ctor {
    ProbeAppend([NSString stringWithFormat:@"CamProbe loaded in %@ home=%@\n", NSBundle.mainBundle.bundleIdentifier, NSHomeDirectory()]);
}
