#import <AppKit/AppKit.h>
#include "chrome/browser/ui/cio/CioPasswords.h"
#include "base/functional/bind.h"
#include "base/task/sequenced_task_runner.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "chrome/browser/profiles/profile.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/autofill/core/common/autofill_prefs.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_prefs_helper.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/common/extension.h"
#include "extensions/browser/disable_reason.h"

namespace cio {
namespace {
AppleConnectionGate connection;
void Notify() {
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioPasswordSettingsChanged" object:nil];
}
class PasswordPreferences final : public extensions::ExtensionRegistryObserver {
 public:
  explicit PasswordPreferences(Profile* profile) : profile_(profile) {
    auto* prefs = profile->GetPrefs();
    // Persist the initial selection once, before observing changes. Never
    // replace an explicit Apple/off choice when its transport is unavailable.
    if (prefs->FindPreference(kPasswordProviderPref)->IsDefaultValue()) {
      const bool apple_installed = extensions::ExtensionRegistry::Get(profile)
          ->GetInstalledExtension(kApplePasswordExtension);
      prefs->SetInteger(kPasswordProviderPref, InitialPasswordProvider(apple_installed,
          prefs->GetBoolean(password_manager::prefs::kCredentialsEnableService)));
      prefs->CommitPendingWrite();
    }
    registrar_.Init(profile->GetPrefs());
    registrar_.Add(kPasswordProviderPref, base::BindRepeating(
        &PasswordPreferences::ProviderChanged, base::Unretained(this)));
    registrar_.Add(password_manager::prefs::kCredentialsEnableService,
        base::BindRepeating(&PasswordPreferences::ServiceChanged, base::Unretained(this)));
    extensions::ExtensionRegistry::Get(profile)->AddObserver(this);
    Apply();
  }
  ~PasswordPreferences() override {
    extensions::ExtensionRegistry::Get(profile_)->RemoveObserver(this);
  }
  Profile* profile() { return profile_; }
  void Apply() {
    if (applying_) return;
    applying_ = true;
    auto* prefs = profile_->GetPrefs();
    auto* registry = extensions::ExtensionRegistry::Get(profile_);
    // Remove only Apple's old extension overrides, exposing the existing user
    // and enterprise values. Do not reset or set address/card preferences.
    // Chromium's removal API CHECKs that ExtensionPrefs registered this ID in
    // ExtensionPrefValueMap. An absent/uninstalled extension has no entry;
    // never call this API speculatively on first launch. OnExtensionLoaded
    // applies the cleanup after a subsequent install has been registered.
    if (registry->GetInstalledExtension(kApplePasswordExtension)) {
      auto* helper = extensions::ExtensionPrefsHelper::Get(profile_);
      using Scope = extensions::ExtensionPrefsHelper::ChromeSettingScope;
      for (const char* name : {autofill::prefs::kAutofillProfileEnabled,
                               autofill::prefs::kAutofillCreditCardEnabled,
                               autofill::prefs::kAutofillEnabledDeprecated}) {
        helper->RemoveExtensionControlledPref(kApplePasswordExtension, name, Scope::kRegular);
      }
    }
    const bool chromium = ChromiumPasswordsAllowed(prefs->GetInteger(kPasswordProviderPref));
    // The password provider is a registered Chromium Profile preference. The
    // standard save preference and ChromePasswordManagerClient's filling gate
    // consume this state; there is no UserDefaults mirror or second vault.
    if (chromium || prefs->GetInteger(kPasswordProviderPref) == 2) {
      if (registry->enabled_extensions().Contains(kApplePasswordExtension))
        extensions::ExtensionRegistrar::Get(profile_)->DisableExtension(
            kApplePasswordExtension, {extensions::disable_reason::DISABLE_USER_ACTION});
    }
    if (!prefs->IsManagedPreference(password_manager::prefs::kCredentialsEnableService))
      prefs->SetBoolean(password_manager::prefs::kCredentialsEnableService, chromium);
    applying_ = false;
    Notify();
  }
  void ProviderChanged() { CancelAllPasswordUI(); Apply(); }
  void ServiceChanged() {
    if (applying_) return;
    auto* prefs = profile_->GetPrefs();
    const bool saving = prefs->GetBoolean(password_manager::prefs::kCredentialsEnableService);
    // Editing the upstream password-saving switch is reflected in Cio's
    // selection. Apple's own false override must not switch the chosen vault.
    const int provider = prefs->GetInteger(kPasswordProviderPref);
    const int updated = ProviderAfterSavingChange(provider, saving);
    if (updated != provider) prefs->SetInteger(kPasswordProviderPref, updated);
    Notify();
  }
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension* extension) override {
    if (extension->id() != kApplePasswordExtension) return;
    // Do not mutate the registry while it is dispatching. An automatic reload
    // after a failed connection must not reset the retry circuit.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<PasswordPreferences> self) {
          if (self) self->Apply();
        }, weak_factory_.GetWeakPtr()));
  }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason) override {
    if (extension->id() == kApplePasswordExtension) Notify();
  }
  void OnExtensionUninstalled(content::BrowserContext*, const extensions::Extension* extension,
                              extensions::UninstallReason) override {
    if (extension->id() == kApplePasswordExtension) Notify();
  }
 private:
  raw_ptr<Profile> profile_;
  bool applying_ = false;
  PrefChangeRegistrar registrar_;
  base::WeakPtrFactory<PasswordPreferences> weak_factory_{this};
};
std::unique_ptr<PasswordPreferences>& Preferences() {
  static auto* preferences = new std::unique_ptr<PasswordPreferences>;
  return *preferences;
}
NSString* TransportDescription() {
  switch (connection.state()) {
    case AppleTransport::kUntried: return @"尚未连接 Apple 宿主。安装并启用官方扩展后，点击网站信息中的 iCloud 密码，按 Apple 界面完成授权／解锁。";
    case AppleTransport::kConnecting: return @"正在连接系统 Apple 密码宿主。授权和解锁由 Apple 界面完成。";
    case AppleTransport::kConnected: return @"Apple Native Messaging 通道已建立；是否授权／解锁请查看官方扩展。通道建立不代表密码填充已验收。";
    case AppleTransport::kNotFound: return @"Native host not found：系统未注册 com.apple.passwordmanager。请检查系统 Apple 密码组件。";
    case AppleTransport::kForbidden: return @"Access to the specified native messaging host is forbidden：宿主来源或系统／企业策略拒绝连接。";
    case AppleTransport::kFailedToStart: return @"Failed to start native messaging host：Apple 宿主无法启动。";
    case AppleTransport::kStaleTarget: return @"页面／分屏焦点已变化，过期的 Apple 密码请求已取消。请手动重试连接；旧结果不会发送到新页面。";
    case AppleTransport::kDisconnected: return @"Apple 原生宿主断开连接（Native host has exited / communication error）。可能是授权取消或宿主拒绝当前浏览器；Cio 未绕过 Apple 检查。自动重试已停止，请检查官方弹窗后手动重试。";
  }
}
}
void InitializePasswordPreferences(Profile* profile) { Preferences() = std::make_unique<PasswordPreferences>(profile); }
void ShutdownPasswordPreferences() { Preferences().reset(); }
bool ChromiumPasswordsEnabled(Profile* profile) {
  return profile && ChromiumPasswordsAllowed(profile->GetPrefs()->GetInteger(kPasswordProviderPref));
}
NSDictionary* PasswordSettingsSnapshot() {
  if (!Preferences()) return @{@"provider": @0, @"status": @"Chromium 尚未初始化。", @"ready": @NO};
  auto* profile = Preferences()->profile();
  auto* prefs = profile->GetPrefs();
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  const int provider = prefs->GetInteger(kPasswordProviderPref);
  const bool installed = registry->GetInstalledExtension(kApplePasswordExtension);
  const bool enabled = registry->enabled_extensions().Contains(kApplePasswordExtension);
  NSString* status;
  if (provider == 0) {
    if (!installed) status = @"未安装 Apple 官方 iCloud 密码扩展。选择仍为 Apple，不会切换到 Chromium 密码库。";
    else if (!enabled) status = @"Apple iCloud 密码扩展已停用或被阻止。请在扩展管理中启用；不会切换到 Chromium 密码库。";
    else status = TransportDescription();
  } else if (provider == 1) {
    status = @"使用 Chromium 本机密码库和 Cio Safe Storage 钥匙串项。首次使用可能需要系统授权。Apple 扩展在此模式下停用。";
    if (!prefs->GetBoolean(password_manager::prefs::kCredentialsEnableService))
      status = @"Chromium 密码保存被扩展或管理策略关闭，请检查引擎密码设置。";
  } else status = @"密码保存与填充已关闭；已有 Chromium 密码保留。Apple 扩展在此模式下停用。";
  return @{@"provider": @(provider), @"status": status, @"ready": @YES,
           @"appleInstalled": @(installed), @"appleEnabled": @(enabled)};
}
NSString* SetPasswordProvider(int provider) {
  if (!Preferences() || !ValidPasswordProvider(provider)) return @"密码设置不可用。";
  auto* prefs = Preferences()->profile()->GetPrefs();
  if (prefs->IsManagedPreference(kPasswordProviderPref)) return @"密码管理器由管理策略指定。";
  if (prefs->IsManagedPreference(password_manager::prefs::kCredentialsEnableService) &&
      prefs->GetBoolean(password_manager::prefs::kCredentialsEnableService) != ChromiumPasswordsAllowed(provider))
    return @"PasswordManagerEnabled 管理策略与所选密码管理器冲突。";
  prefs->SetInteger(kPasswordProviderPref, provider);
  Preferences()->Apply();
  prefs->CommitPendingWrite();
  return nil;
}
void RetryAppleConnection() {
  if (!Preferences() || Preferences()->profile()->GetPrefs()->GetInteger(kPasswordProviderPref) != 0) return;
  connection.Retry();
  Notify();
  // A user initiated retry is the only host-controlled reload. Apple's own
  // service worker keeps all pairing, capabilities, TOTP and writeback logic.
  auto* registry = extensions::ExtensionRegistry::Get(Preferences()->profile());
  if (registry->enabled_extensions().Contains(kApplePasswordExtension))
    extensions::ExtensionRegistrar::Get(Preferences()->profile())->ReloadExtension(kApplePasswordExtension);
}
void NotifyTransport() {
  content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce([] {
    if (Preferences()) Notify();
  }));
}
uint64_t BeginAppleConnection() { auto epoch = connection.Begin(); NotifyTransport(); return epoch; }
void AppleConnectionLaunched(uint64_t epoch) { connection.Connected(epoch); NotifyTransport(); }
void AppleConnectionFailed(uint64_t epoch, const std::string& error) {
  if (error.find("Cio canceled an obsolete") == 0) connection.Fail(epoch, AppleTransport::kStaleTarget);
  else if (error == "Specified native messaging host not found.") connection.Fail(epoch, AppleTransport::kNotFound);
  else if (error == "Access to the specified native messaging host is forbidden.") connection.Fail(epoch, AppleTransport::kForbidden);
  else if (error == "Failed to start native messaging host.") connection.Fail(epoch, AppleTransport::kFailedToStart);
  else connection.Fail(epoch, AppleTransport::kDisconnected);
  NotifyTransport();
}
}  // namespace cio
