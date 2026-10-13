#pragma once
#include <memory>
#include "components/permissions/permission_prompt.h"
namespace cio {
std::unique_ptr<permissions::PermissionPrompt> CreatePermissionPrompt(
    content::WebContents* contents, permissions::PermissionPrompt::Delegate* delegate);
}
