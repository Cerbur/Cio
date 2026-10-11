#pragma once
#include <string>
#include "chrome/browser/ui/extensions/extension_popup_types.h"

class BrowserWindowInterface;
namespace cio {
// False leaves stock Chrome's Views implementation in charge.
bool HandleExtensionSidePanel(BrowserWindowInterface*, const std::string&,
                              bool toggle, bool close, bool contextual);
bool HandleExtensionPopup(BrowserWindowInterface*, const std::string&,
                          ShowPopupCallback*);
}
