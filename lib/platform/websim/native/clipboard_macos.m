/**
 * macOS platform helpers for WebSim native:
 * - Clipboard: copy MP4 file to pasteboard
 * - Media: enable mic/camera permissions on WKWebView
 * - Audio: native mic capture + speaker playback via AVFoundation
 */

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "recorder_c.h"

int websim_clipboard_copy_video(const char *path) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSURL *fileURL = [NSURL fileURLWithPath:nsPath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:nsPath]) {
            return -1;
        }

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];

        BOOL ok = [pb writeObjects:@[fileURL]];
        return ok ? 0 : -2;
    }
}

/**
 * WKUIDelegate that auto-grants microphone/camera permissions.
 * Without this, getUserMedia() fails silently in WKWebView.
 */
@interface WebSimUIDelegate : NSObject <WKUIDelegate>
@end

@implementation WebSimUIDelegate

- (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    type:(WKMediaCaptureType)type
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler
    API_AVAILABLE(macos(12.0)) {
    // Auto-grant mic/camera access for the simulator
    decisionHandler(WKPermissionDecisionGrant);
}

@end

static WebSimUIDelegate *g_uiDelegate = nil;

/**
 * Enable media capture (mic/camera) on a webview's WKWebView.
 * Must be called after webview_create, before loading content.
 *
 * @param nswindow The NSWindow* from webview_get_native_handle
 */
static WKWebView *findWKWebView(NSView *view) {
    if ([view isKindOfClass:[WKWebView class]]) {
        return (WKWebView *)view;
    }
    for (NSView *subview in view.subviews) {
        WKWebView *found = findWKWebView(subview);
        if (found) return found;
    }
    return nil;
}

void websim_enable_media_capture(void *nswindow) {
    if (!nswindow) return;

    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;

        // Recursively find WKWebView in the view hierarchy
        WKWebView *webView = findWKWebView(window.contentView);
        if (webView) {
            if (!g_uiDelegate) {
                g_uiDelegate = [[WebSimUIDelegate alloc] init];
            }
            webView.UIDelegate = g_uiDelegate;
            NSLog(@"[WebSim] Media capture enabled on WKWebView");
        } else {
            NSLog(@"[WebSim] WARNING: WKWebView not found in window hierarchy");
        }
    }
}

/* Native audio capture removed — using localhost HTTP + WebRTC getUserMedia instead */
