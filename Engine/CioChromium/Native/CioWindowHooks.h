#pragma once
#include <memory>
#include "base/functional/callback.h"
namespace content { class WebContents; class JavaScriptDialogManager; }
#ifdef __OBJC__
#import <AppKit/AppKit.h>
#endif
class Browser;
class GURL;
namespace base { class FilePath; }
namespace download { class DownloadItem; }
namespace cio {
void OnBrowserWindowCreated(Browser* browser);
void OnBrowserWindowDestroyed(Browser* browser);
void EnsureCioUIStarted(Browser* browser);
Browser* CioBrowser();
void RefreshDevTools();
void ShutdownDownloads();
content::JavaScriptDialogManager* NativeJavaScriptDialogs();
bool ShowHungRenderer(content::WebContents* contents, base::RepeatingClosure restart);
bool HideHungRenderer(content::WebContents* contents);
base::FilePath DownloadPath(download::DownloadItem* item);
bool OpenNewTab(Browser* browser, const GURL& url);
bool AdoptPopup(Browser* browser, std::unique_ptr<content::WebContents>& contents, const GURL& url);
bool CanFocusBrowser(Browser* browser);
#ifdef __OBJC__
NSWindow* CioMainWindow();
void SetCreatingHostView(NSView* view);
#endif
}
