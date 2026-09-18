//
//  NativeBrowser-Bridging-Header.h
//  NativeBrowser
//
//  Objective-C interfaces that Swift is allowed to see. CEF C++ types are
//  intentionally absent from this header: all Chromium access goes through the
//  Objective-C++ bridge (see ARCHITECTURE.md section 8).
//

#import "BrowserBridge.h"
#import "CEFProcessHost.h"
