#pragma once

#import <AppKit/AppKit.h>
#include <memory>
#include <string>
#include "chrome/browser/ui/cio/CioExtensionPanelHooks.h"

class Browser;
class BrowserWindowInterface;
@class BrowserBridge;
namespace content { class WebContents; }

namespace cio {
// One adapter per Cio tab. Chromium continues to own action state, permissions
// and extension hosts; AppKit supplies their visible surfaces.
class TabExtensions {
 public:
  TabExtensions(Browser*, content::WebContents*, BrowserBridge*);
  ~TabExtensions();
  NSArray<NSDictionary<NSString*, id>*>* Snapshot();
  void Execute(NSString* identifier);
  void ShowPanel(const std::string& identifier, bool toggle, bool contextual);
  void ClosePanel(const std::string& identifier);
  void Reparent(NSView* parent);
  NSRect Layout(NSRect bounds);
  void ClosePopup();
  bool HasPopup() const;
  void TriggerPopupForAPI(const std::string&, ShowPopupCallback);
  void UpdateVisibility();
 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
}
