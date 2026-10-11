#pragma once
#include "chrome/browser/extensions/extension_uninstall_dialog.h"

namespace cio {
std::unique_ptr<extensions::ExtensionUninstallDialog> CreateExtensionUninstallDialog(
    Profile* profile, gfx::NativeWindow parent,
    extensions::ExtensionUninstallDialog::Delegate* delegate);
}
