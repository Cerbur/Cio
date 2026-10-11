#pragma once
#include <memory>
#include <string>
#include "base/functional/callback.h"
namespace content { class WebContents; class JavaScriptDialogManager; }
#ifdef __OBJC__
#import <AppKit/AppKit.h>
#endif
class Browser;
class GURL;
namespace base { class FilePath; }
namespace download { class DownloadItem; }
namespace find_in_page { class FindNotificationDetails; }
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
void ShowFindBar(Browser* browser, bool focus);
void HideFindBar(Browser* browser);
void RestoreFindFocus(Browser* browser);
bool FindBarHasFocus(Browser* browser);
void UpdateFindResult(Browser* browser,
                      const find_in_page::FindNotificationDetails& result,
                      const std::u16string& query);
#ifdef __OBJC__
NSWindow* CioMainWindow();
void SetCreatingHostView(NSView* view);
#endif
}
