#pragma once
#include <memory>
#include <optional>
#include <string>
#include "base/functional/callback.h"
namespace content { class WebContents; class JavaScriptDialogManager; class WeakDocumentPtr; }
namespace url { class Origin; }
#ifdef __OBJC__
#import <AppKit/AppKit.h>
#endif
class Browser;
class GURL;
namespace base { class FilePath; }
namespace download { class DownloadItem; }
namespace find_in_page { class FindNotificationDetails; }
namespace views { class Widget; class WidgetDelegate; class DialogDelegate; }
namespace cio {
void OnBrowserWindowCreated(Browser* browser);
void OnBrowserWindowDestroyed(Browser* browser);
void EnsureCioUIStarted(Browser* browser);
Browser* CioBrowser();
void RefreshDevTools();
void ShutdownDownloads();
content::JavaScriptDialogManager* NativeJavaScriptDialogs();
bool ShowExternalProtocolDialog(content::WebContents* contents, const GURL& url,
    const std::u16string& program_name, const std::optional<url::Origin>& origin,
    content::WeakDocumentPtr initiator_document);
bool ShowHungRenderer(content::WebContents* contents, base::RepeatingClosure restart);
bool HideHungRenderer(content::WebContents* contents);
std::unique_ptr<views::Widget> CreateWebAuthnDialog(
    views::WidgetDelegate* view, content::WebContents* contents);
bool ShowWebAuthnDialog(views::Widget* widget);
views::Widget* CreateMediaPickerDialog(views::DialogDelegate* view, content::WebContents* contents);
std::optional<base::FilePath> DownloadPath(download::DownloadItem* item);
bool OpenNewTab(Browser* browser, const GURL& url);
void AdoptExtensionTab(Browser* browser, content::WebContents* contents, bool active);
bool AdoptPopup(Browser* browser, std::unique_ptr<content::WebContents>& contents, const GURL& url);
bool CanFocusBrowser(Browser* browser);
void ActivatePictureInPictureInitiator(content::WebContents* contents);
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
