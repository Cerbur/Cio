#pragma once
#include <memory>
#include "extensions/browser/extension_install_prompt_client.h"

class Profile;
#ifdef __OBJC__
@class NSWindow;
#endif
class ExtensionInstallPromptShowParams;
namespace views { class Widget; }
namespace extensions {
class Extension;
class CrxInstallError;
class InstallPromptData;
}

namespace cio {
#ifdef __OBJC__
// Native confirmations share the key/visibility and floating-window guard.
bool CanInteractWithExtensionPrompt(NSWindow* window);
#endif
// Returns false outside the hosted runtime, leaving stock Chrome UI intact.
bool ShowExtensionInstalled(Profile* profile, const extensions::Extension* extension);
bool ShowExtensionInstallError(const extensions::CrxInstallError& error);
bool ShowExtensionInstallSheet(views::Widget* widget);
// Moves the prompt/callback only for ordinary installs handled by Cio.
// Specialized approvals keep Chromium's original confirmation UI.
bool ShowExtensionInstallPrompt(
    std::unique_ptr<ExtensionInstallPromptShowParams>& params,
    extensions::ExtensionInstallPromptClient::DoneCallback& callback,
    std::unique_ptr<extensions::InstallPromptData>& prompt);
}
