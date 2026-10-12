"""Password integration hooks for the exact pinned Chromium source.

All substitutions are checked against immutable stock backups by the build
script. Only the Cio hosted browser process takes these branches.
"""

def prepare_password_overlay(patch):
    def include(path, anchor):
        patch(path, anchor, anchor + '\n#include "build/build_config.h"\n'
              '#if BUILDFLAG(IS_MAC)\n#include "base/command_line.h"\n'
              '#include "chrome/browser/ui/cio/CioPasswords.h"\n#endif')

    hosted = 'base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")'
    def branch(body):
        return '\n#if BUILDFLAG(IS_MAC)\n  if (' + hosted + ') {\n' + body + '\n  }\n#endif\n'

    client = 'chrome/browser/password_manager/chrome_password_manager_client.cc'
    include(client, '#include "chrome/browser/password_manager/chrome_password_manager_client.h"')
    patch(client, 'bool ChromePasswordManagerClient::IsFillingEnabled(\n'
          '    const url::Origin& origin,\n    base::optional_ref<const GURL> url) const {',
          'bool ChromePasswordManagerClient::IsFillingEnabled(\n'
          '    const url::Origin& origin,\n    base::optional_ref<const GURL> url) const {' +
          branch('    if (!cio::ChromiumPasswordsEnabled(GetProfile())) return false;'))
    for signature, body in (
        ('bool ChromePasswordManagerClient::IsAutoSignInEnabled() const {',
         '    if (!cio::ChromiumPasswordsEnabled(GetProfile())) return false;'),
        ('    bool update_password) {',
         '    if (!cio::ChromiumPasswordsEnabled(GetProfile())) return false;'),
    ):
        patch(client, signature, signature + branch(body))

    patch(client, '  return ChromeDeviceAuthenticatorFactory::GetForProfile(\n'
          '      GetProfile(), web_contents()->GetTopLevelNativeWindow(), params);',
          '  auto authenticator = ChromeDeviceAuthenticatorFactory::GetForProfile(\n'
          '      GetProfile(), web_contents()->GetTopLevelNativeWindow(), params);' +
          branch('    return cio::BindPasswordAuthenticator(std::move(authenticator), web_contents());') +
          '\n  return authenticator;')

    # Final renderer handoff rechecks the upstream client preference. This
    # prevents an already cached suggestion from filling after a provider change.
    driver = 'components/password_manager/content/browser/content_password_manager_driver.cc'
    patch(driver, '#include "components/password_manager/content/browser/content_password_manager_driver.h"',
          '#include "components/password_manager/content/browser/content_password_manager_driver.h"\n'
          '#include "base/command_line.h"')
    deny = ('  if (' + hosted + ' &&\n'
            '      !client_->IsFillingEnabled(GetLastCommittedOrigin())) {\n')
    for signature, result in (
        ('void ContentPasswordManagerDriver::FillField(\n'
         '    autofill::FieldRendererId triggering_field_id,\n'
         '    const std::u16string& value,\n'
         '    autofill::FieldPropertiesFlags field_flags,\n'
         '    base::OnceCallback<void(bool)> success_callback) {',
         '    std::move(success_callback).Run(false);\n    return;'),
        ('void ContentPasswordManagerDriver::FillSuggestion(\n'
         '    const std::u16string& username,\n'
         '    const std::u16string& password,\n'
         '    base::OnceCallback<void(bool)> success_callback) {',
         '    std::move(success_callback).Run(false);\n    return;'),
        ('    autofill::AutofillSuggestionTriggerSource suggestion_source) {', '    return;'),
        ('void ContentPasswordManagerDriver::FillIntoFocusedField(\n'
         '    bool is_password,\n    const std::u16string& credential) {', '    return;'),
        ('void ContentPasswordManagerDriver::GeneratedPasswordAccepted(\n'
         '    const std::u16string& password) {', '    return;'),
        ('void ContentPasswordManagerDriver::PropagateFillDataOnParsingCompletion(\n'
         '    const autofill::PasswordFormFillData& form_data) {', '    return;'),
    ):
        patch(driver, signature, signature + '\n' + deny + result + '\n  }')

    ui = 'chrome/browser/ui/passwords/manage_passwords_ui_controller.cc'
    include(ui, '#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"')
    anchor = '''  // If Actor is operating on the tab, suppress all popups.
  if (passwords_data_.client()->IsActorTaskActive()) {
    ClearPopUpFlagForBubble();
  }
'''
    patch(ui, anchor, anchor + branch('''    if (GetState() != last_page_action_state_) cio::HidePasswordBubble(web_contents());
    last_page_action_state_ = GetState();
    if (IsAutomaticallyOpeningBubble() || bubble_status_ == BubbleStatus::SHOULD_POP_UP_WITH_FOCUS) {
      QueueOrShowBubble(/*user_action=*/false);
      ClearPopUpFlagForBubble();
    }
    return;'''))
    signature = 'void ManagePasswordsUIController::ShowBubbleWithoutUserInteraction() {'
    patch(ui, signature, signature + branch('    ShowBubble();\n    return;'))
    # A Cio credential request must never instantiate the Chrome Views chooser
    # for a background pane and then take the global current window's focus.
    signature = '''  DCHECK(!local_credentials.empty());
  if (!HasBrowserWindow()) {'''
    patch(ui, signature, '  DCHECK(!local_credentials.empty());' + branch(
        '    if (!cio::CanPresentPasswordUI(web_contents()) ||\n'
        '        !cio::ChromiumPasswordsEnabled(Profile::FromBrowserContext(web_contents()->GetBrowserContext()))) return false;') +
        '\n  if (!HasBrowserWindow()) {')

    dialogs = 'chrome/browser/ui/views/tab_dialogs_views.cc'
    include(dialogs, '#include "chrome/browser/ui/views/tab_dialogs_views.h"')
    for signature, body in (
        ('void TabDialogsViews::ShowManagePasswordsBubble(bool user_action) {',
         '    cio::ShowPasswordBubble(web_contents_, user_action);\n    return;'),
        ('void TabDialogsViews::HideManagePasswordsBubble() {',
         '    cio::HidePasswordBubble(web_contents_);\n    return;'),
    ):
        patch(dialogs, signature, signature + branch(body))

    popup = 'chrome/browser/ui/views/autofill/popup/popup_view_views.cc'
    include(popup, '#include "chrome/browser/ui/views/autofill/popup/popup_view_views.h"')
    signature = '''    std::optional<const AutofillPopupView::SubPopupConfig> sub_popup_config) {'''
    patch(popup, signature, signature + branch(
        '    if (controller && controller->GetMainFillingProduct() == FillingProduct::kPassword)\n'
        '      return cio::CreatePasswordSuggestions(controller);'))

    generation = 'chrome/browser/ui/views/passwords/password_generation_popup_view_views.cc'
    include(generation, '#include "chrome/browser/ui/views/passwords/password_generation_popup_view_views.h"')
    signature = '''PasswordGenerationPopupView* PasswordGenerationPopupView::Create(
    base::WeakPtr<PasswordGenerationPopupController> controller) {'''
    patch(generation, signature, signature + branch('    return cio::CreatePasswordGeneration(controller);'))
    generation_controller = 'chrome/browser/ui/passwords/password_generation_popup_controller_impl.cc'
    include(generation_controller, '#include "chrome/browser/ui/passwords/password_generation_popup_controller_impl.h"')
    signature = '''bool PasswordGenerationPopupControllerImpl::HandleKeyPressEvent(
    const input::NativeWebKeyboardEvent& event) {'''
    patch(generation_controller, signature, signature + branch(
        '    if (cio::PasswordIMEComposing(web_contents())) return false;'))

    chooser = 'chrome/browser/ui/views/passwords/account_chooser_dialog_view.cc'
    include(chooser, '#include "chrome/browser/ui/views/passwords/account_chooser_dialog_view.h"')
    signature = '''std::unique_ptr<AccountChooserPrompt> CreateAccountChooserPromptView(
    CredentialManagerDialogController* controller,
    content::WebContents* web_contents) {'''
    patch(chooser, signature, signature + branch(
        '    return cio::CreatePasswordAccountChooser(controller, web_contents);'))

    cross = 'chrome/browser/ui/views/passwords/password_cross_domain_confirmation_popup_view_views.cc'
    include(cross, '#include "chrome/browser/ui/views/passwords/password_cross_domain_confirmation_popup_view_views.h"')
    signature = '''    base::OnceClosure cancel_callback) {
  auto* view = new PasswordCrossDomainConfirmationPopupViewViews('''
    patch(cross, signature, '    base::OnceClosure cancel_callback) {' + branch(
        '    return cio::ShowPasswordCrossDomain(controller, std::move(confirmation_callback), std::move(cancel_callback));') +
        '\n  auto* view = new PasswordCrossDomainConfirmationPopupViewViews(')

    preference = 'chrome/browser/extensions/api/preference/preference_api.cc'
    include(preference, '#include "chrome/browser/extensions/api/preference/preference_api.h"')
    signature = '''  EXTENSION_FUNCTION_VALIDATE(browser_pref_value->type() == pref->GetType());'''
    patch(preference, signature, signature + branch(
        '    if (extension_id() == cio::kApplePasswordExtension &&\n'
        '        !cio::AppleMayControlPreference(browser_pref))\n'
        '      return RespondNow(Error("Cio preserves address and payment autofill; iCloud Passwords may control only password settings."));'))

    messaging = 'chrome/browser/extensions/api/messaging/native_message_process_host.cc'
    include(messaging, '#include "chrome/browser/extensions/api/messaging/native_message_process_host.h"')
    patch('chrome/browser/extensions/api/messaging/native_message_process_host.h',
          '  bool closed_;', '  bool closed_;\n  uint64_t cio_apple_connection_epoch_ = 0;')
    condition = 'native_host_name_ == cio::kApplePasswordHost && source_extension_id_ == cio::kApplePasswordExtension'
    signature = '  task_runner_ = content::GetIOThreadTaskRunner({});'
    patch(messaging, signature, signature + branch(
        '    if (' + condition + ') cio::RegisterApplePasswordHost(this);'))
    signature = 'NativeMessageProcessHost::~NativeMessageProcessHost() {'
    patch(messaging, signature, signature + branch(
        '    if (' + condition + ') cio::UnregisterApplePasswordHost(this);'))
    signature = '  client_ = client;\n  task_runner_->PostTask('

    patch(messaging, signature, '  client_ = client;' + branch(
        '    if (' + condition + ') {\n'
        '      cio_apple_connection_epoch_ = cio::BeginAppleConnection();\n'
        '      cio::ApplePasswordHostBegan(this, cio_apple_connection_epoch_);\n    }\n'
        '    if (' + condition + ' && !cio_apple_connection_epoch_) {\n'
        '      Close("Cio paused iCloud Passwords after a connection attempt. Retry explicitly in Cio Settings.");\n'
        '      return;\n    }') + '\n  task_runner_->PostTask(')
    signature = '  process_ = std::move(process);'
    patch(messaging, signature, signature + branch(
        '    if (' + condition + ') cio::AppleConnectionLaunched(cio_apple_connection_epoch_);'))
    signature = '''  if (!closed_) {
    closed_ = true;'''
    patch(messaging, signature, signature + branch(
        '    if (' + condition + ' && error_message.find("Cio paused") != 0)\n'
        '      cio::AppleConnectionFailed(cio_apple_connection_epoch_, error_message);'))

    dispatcher = 'chrome/browser/extensions/api/messaging/chrome_native_message_port_dispatcher.cc'
    include(dispatcher, '#include "chrome/browser/extensions/api/messaging/chrome_native_message_port_dispatcher.h"')
    dispatcher_header = 'chrome/browser/extensions/api/messaging/chrome_native_message_port_dispatcher.h'
    patch(dispatcher_header, 'namespace extensions {',
          'namespace cio { class ApplePasswordRouting; }\n\nnamespace extensions {')
    patch(dispatcher_header, '  std::unique_ptr<NativeMessageHost> host_;',
          '  std::shared_ptr<cio::ApplePasswordRouting> cio_apple_routing_;\n  std::unique_ptr<NativeMessageHost> host_;')
    signature = '  DCHECK(message_service_task_runner_->BelongsToCurrentThread());'
    patch(dispatcher, signature + '\n  host_task_runner_->PostTask(\n      FROM_HERE,\n      base::BindOnce(&NativeMessageHost::Start',
          signature + branch('    cio_apple_routing_ = cio::AppleRoutingForHost(host_.get());') +
          '\n  host_task_runner_->PostTask(\n      FROM_HERE,\n      base::BindOnce(&NativeMessageHost::Start')
    patch(dispatcher, signature + '\n  host_task_runner_->PostTask(\n      FROM_HERE, base::BindOnce(&NativeMessageHost::OnMessage',
          signature + branch('''    if (!cio::CaptureApplePasswordRequest(cio_apple_routing_, message)) {
      if (port_) port_->CloseChannel("Cio canceled an obsolete iCloud Passwords request. Retry in Cio Settings.");
      return;
    }''') + '\n  host_task_runner_->PostTask(\n      FROM_HERE, base::BindOnce(&NativeMessageHost::OnMessage')
    signature = '''  message_service_task_runner_->PostTask(
      FROM_HERE, base::BindOnce(&NativeMessagePort::PostMessageFromNativeHost,
                                port_, message));'''
    patch(dispatcher, signature, branch('''    if (cio_apple_routing_) {
      message_service_task_runner_->PostTask(FROM_HERE, base::BindOnce(
          [](std::shared_ptr<cio::ApplePasswordRouting> routing,
             base::WeakPtr<NativeMessagePort> port, std::string response) {
            if (!port) return;
            if (cio::AcceptApplePasswordResponse(routing, response)) port->PostMessageFromNativeHost(response);
            else port->CloseChannel("Cio canceled an obsolete iCloud Passwords response. Retry in Cio Settings.");
          }, cio_apple_routing_, port_, message));
      return;
    }''') + signature)

    # This pinned version gates generation on sync. Cio uses a local store:
    # retain the stock generator and all frame-helper saving/site checks while
    # allowing the local save-enabled path without adding cloud account sync.
    feature = 'components/password_manager/core/browser/password_feature_manager_impl.cc'
    patch(feature, '#include "base/feature_list.h"', '#include "base/feature_list.h"\n#include "base/command_line.h"')
    signature = 'bool PasswordFeatureManagerImpl::IsGenerationEnabled() const {'
    patch(feature, signature, signature + '\n  if (' + hosted + ')\n'
          '    return pref_service_ && pref_service_->GetBoolean(prefs::kCredentialsEnableService);\n')
