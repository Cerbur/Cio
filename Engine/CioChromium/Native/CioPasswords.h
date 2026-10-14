#pragma once
#include <memory>
#include <string>
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/ui/cio/CioPasswordPolicy.h"
#ifdef __OBJC__
@class NSDictionary, NSString;
#endif

class Profile;
class PasswordGenerationPopupController;
class PasswordGenerationPopupView;
class PasswordCrossDomainConfirmationPopupControllerInterface;
class PasswordCrossDomainConfirmationPopupView;
class CredentialManagerDialogController;
class AccountChooserPrompt;
class AutoSigninFirstRunPrompt;
namespace content { class WebContents; }
namespace autofill { class AutofillPopupController; class AutofillPopupView; }
namespace device_reauth { class DeviceAuthenticator; }
namespace cio {
void InitializePasswordPreferences(Profile* profile);
void ShutdownPasswordPreferences();
bool ChromiumPasswordsEnabled(Profile* profile);
bool ShowPasswordBubble(content::WebContents* contents, bool user_action);
void HidePasswordBubble(content::WebContents* contents);
void CancelPasswordUI(content::WebContents* contents);
void CancelAllPasswordUI();
bool PasswordUIHasFocus(content::WebContents* contents);
bool CanPresentPasswordUI(content::WebContents* contents);
bool PasswordIMEComposing(content::WebContents* contents);
void PasswordAccountAuthenticationFailed(CredentialManagerDialogController* controller);
std::unique_ptr<device_reauth::DeviceAuthenticator> BindPasswordAuthenticator(
    std::unique_ptr<device_reauth::DeviceAuthenticator> authenticator,
    content::WebContents* contents);
base::WeakPtr<autofill::AutofillPopupView> CreatePasswordSuggestions(
    base::WeakPtr<autofill::AutofillPopupController> controller);
PasswordGenerationPopupView* CreatePasswordGeneration(
    base::WeakPtr<PasswordGenerationPopupController> controller);
std::unique_ptr<AccountChooserPrompt> CreatePasswordAccountChooser(
    CredentialManagerDialogController* controller, content::WebContents* contents);
AutoSigninFirstRunPrompt* CreatePasswordAutoSigninPrompt(
    CredentialManagerDialogController* controller, content::WebContents* contents);
base::WeakPtr<PasswordCrossDomainConfirmationPopupView> ShowPasswordCrossDomain(
    base::WeakPtr<PasswordCrossDomainConfirmationPopupControllerInterface> controller,
    base::OnceClosure confirm, base::OnceClosure cancel);
// Called only for the official extension/host pair. Secret payloads are opaque.
uint64_t BeginAppleConnection();
void AppleConnectionLaunched(uint64_t epoch);
void AppleConnectionFailed(uint64_t epoch, const std::string& chromium_error);
class ApplePasswordRouting;
void RegisterApplePasswordHost(void* host);
void UnregisterApplePasswordHost(void* host);
std::shared_ptr<ApplePasswordRouting> AppleRoutingForHost(void* host);
void ApplePasswordHostBegan(void* host, uint64_t epoch);
bool CaptureApplePasswordRequest(const std::shared_ptr<ApplePasswordRouting>& routing, const std::string& message);
bool AcceptApplePasswordResponse(const std::shared_ptr<ApplePasswordRouting>& routing, const std::string& message);
void CancelApplePasswordRequests(content::WebContents* contents);
content::WebContents* PasswordContentsForExtensionTab(int tab_id);
#ifdef __OBJC__
NSDictionary* PasswordSettingsSnapshot();
NSString* SetPasswordProvider(int provider);
void RetryAppleConnection();
#endif
}
