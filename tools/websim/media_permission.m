/**
 * Auto-grant media capture permissions for WKWebView.
 * Without this, getUserMedia() shows a permission dialog that
 * may get permanently denied in webview.
 */

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface WebSimUIDelegate : NSObject <WKUIDelegate>
@end

@implementation WebSimUIDelegate

- (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    type:(WKMediaCaptureType)type
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler
    API_AVAILABLE(macos(12.0)) {
    decisionHandler(WKPermissionDecisionGrant);
}

@end

static WebSimUIDelegate *g_delegate = nil;

static WKWebView *findWKWebView(NSView *view) {
    if ([view isKindOfClass:[WKWebView class]]) return (WKWebView *)view;
    for (NSView *sub in view.subviews) {
        WKWebView *found = findWKWebView(sub);
        if (found) return found;
    }
    return nil;
}

void websim_enable_media(void *nswindow) {
    if (!nswindow) return;
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        WKWebView *wv = findWKWebView(window.contentView);
        if (wv) {
            if (!g_delegate) g_delegate = [[WebSimUIDelegate alloc] init];
            wv.UIDelegate = g_delegate;
            NSLog(@"[WebSim] Media permissions auto-granted");
        }
    }
}
