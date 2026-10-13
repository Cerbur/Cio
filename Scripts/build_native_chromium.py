#!/usr/bin/env python3
"""Apply Cio's version-pinned overlay and incrementally build its native engine."""
import fcntl
import os
import signal
import hashlib
import json
from pathlib import Path
import shutil
import sys
from types import SimpleNamespace

from try_chromium_build import Attempt, VERSION, SOURCE_SHA256

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/ChromiumBuild/src"
BACKUPS = ROOT / "build/ChromiumBuild/native-originals"

PATCHES = {}
def patch(relative, before, after):
    path = SOURCE / relative
    backup = BACKUPS / relative
    if relative not in PATCHES:
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            shutil.copy2(path, backup)
        PATCHES[relative] = backup.read_text()
    text = PATCHES[relative]
    if text.count(before) != 1:
        raise RuntimeError("Pinned Chromium patch no longer matches: " + relative)
    PATCHES[relative] = text.replace(before, after)

def prepare():
    marker = json.loads((SOURCE / ".cio-source.json").read_text())
    if marker.get("sha256") != SOURCE_SHA256:
        raise RuntimeError("Native overlay requires the pinned Chromium " + VERSION)
    destination = SOURCE / "chrome/browser/ui/cio"
    destination.mkdir(parents=True, exist_ok=True)
    for directory in (ROOT / "Engine/CioChromium/Native", ROOT / "Engine/CioChromium/Public"):
        for path in directory.iterdir():
            if path.suffix in (".h", ".mm"):
                target = destination / path.name
                if not target.exists() or target.read_bytes() != path.read_bytes():
                    shutil.copy2(path, target)
    patch("chrome/BUILD.gn", '      "app/chrome_main_mac.mm",\n',
          '      "app/chrome_main_mac.mm",\n'
          '      "browser/ui/cio/CioNativeRuntime.mm",\n'
          '      "browser/ui/cio/CioHostedMessagePump.mm",\n'
          '      "browser/ui/cio/BrowserBridge.mm",\n'
          '      "browser/ui/cio/CioBrowserWindow.mm",\n'
          '      "browser/ui/cio/CioDialogs.mm",\n'
          '      "browser/ui/cio/CioPermissions.mm",\n'
          '      "browser/ui/cio/CioWebAuthnDialogs.mm",\n'
          '      "browser/ui/cio/CioExtensionUI.mm",\n'
          '      "browser/ui/cio/CioExtensionRemoval.mm",\n'
          '      "browser/ui/cio/CioTabExtensions.mm",\n'
          '      "browser/ui/cio/CioApplePasswordRouting.mm",\n'
          '      "browser/ui/cio/CioPasswordPreferences.mm",\n'
          '      "browser/ui/cio/CioPasswords.mm",\n'
          '      "browser/ui/cio/CioRoot.mm",\n')
    # The component build does not export CrApplication's constructors or its
    # pool policy. Export the three entry points the hosted subclass uses,
    # without changing the message-pump header or stock Chromium behavior.
    pump = "base/message_loop/message_pump_apple.mm"
    for declaration in ("MessagePumpCrApplication::MessagePumpCrApplication() = default;",
                        "MessagePumpCrApplication::~MessagePumpCrApplication() = default;",
                        "bool MessagePumpCrApplication::ShouldCreateAutoreleasePool() {"):
        patch(pump, declaration, "BASE_EXPORT " + declaration)
    patch("chrome/app/chrome_main.cc", '#include "chrome/app/chrome_main_mac.h"',
          '#include "chrome/app/chrome_main_mac.h"\n'
          '#include "chrome/browser/ui/cio/CioNativeRuntime.h"')
    patch("chrome/app/chrome_main.cc",
          '  ChromeMainDelegate chrome_main_delegate(\n'
          '      {.exe_entry_point_ticks = base::TimeTicks::Now()});',
          '#if BUILDFLAG(IS_MAC)\n'
          '  base::CommandLine::Init(argc, argv);\n'
          '  StartupTimestamps timestamps{.exe_entry_point_ticks = base::TimeTicks::Now()};\n'
          '  std::unique_ptr<ChromeMainDelegate> chrome_main_delegate =\n'
          '      cio::IsHostedBrowser() ? cio::CreateMainDelegate(timestamps)\n'
          '                             : std::make_unique<ChromeMainDelegate>(timestamps);\n'
          '#else\n'
          '  ChromeMainDelegate chrome_main_delegate(\n'
          '      {.exe_entry_point_ticks = base::TimeTicks::Now()});\n'
          '#endif')
    patch("chrome/app/chrome_main.cc", '  content::ContentMainParams params(&chrome_main_delegate);',
          '#if BUILDFLAG(IS_MAC)\n'
          '  content::ContentMainParams params(chrome_main_delegate.get());\n'
          '#else\n'
          '  content::ContentMainParams params(&chrome_main_delegate);\n'
          '#endif')
    patch("chrome/app/chrome_main.cc", '  int rv = content::ContentMain(std::move(params));',
          '  int rv;\n#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::IsHostedBrowser())\n'
          '    rv = cio::RunHostedContent(std::move(params), std::move(chrome_main_delegate));\n'
          '  else\n#endif\n'
          '    rv = content::ContentMain(std::move(params));')
    factory = "chrome/browser/ui/views/frame/browser_window_factory.cc"
    patch(factory, '#include "build/build_config.h"',
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "base/command_line.h"\n'
          '#include "chrome/browser/ui/cio/CioBrowserWindow.h"\n#endif')
    patch(factory, '                                   bool in_tab_dragging) {',
          '                                   bool in_tab_dragging) {\n'
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '    return std::unique_ptr<BrowserWindow, BrowserWindowDeleter>(new CioBrowserWindow(browser));\n'
          '#endif')
    app = "chrome/browser/chrome_browser_application_mac.mm"
    patch(app, '- (void)terminate:(id)sender {',
          '- (void)terminate:(id)sender {\n'
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")) {\n'
          '    [super terminate:sender];\n    return;\n  }')
    # Cio owns NSApplication's delegate and its SwiftUI menus. Chrome's
    # AppController assumes its own menu IDs and must never observe this shell.
    main_mac = "chrome/browser/chrome_browser_main_mac.mm"
    patch(main_mac, '  // Create the app delegate by requesting the shared AppController.',
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '    return content::RESULT_CODE_NORMAL_EXIT;\n\n'
          '  // Create the app delegate by requesting the shared AppController.')
    controller = "chrome/browser/app_controller_mac.mm"
    patch(controller, '+ (AppController*)sharedController {',
          '+ (AppController*)sharedController {\n'
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '    return nil;  // AppKit delegate, menus and lifecycle belong to Cio.\n')
    patch(controller, 'Profile* GetSafeProfile(Profile* loaded_profile) {',
          'Profile* GetSafeProfile(Profile* loaded_profile) {\n'
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '    return loaded_profile;\n')
    tabs = "chrome/browser/ui/tabs/tab_features.cc"
    patch(tabs, '#include <memory>', '#include <memory>\n#include "base/command_line.h"')
    patch(tabs, '  if (features::IsImmersiveReadAnythingEnabled()) {',
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")) {\n'
          '    // Cio has no Chrome Views reading side panel. Do not install a\n'
          '    // controller whose tab-detach handler requires that panel.\n'
          '  } else if (features::IsImmersiveReadAnythingEnabled()) {')
    # Embedded find UI is per tab. The stock macOS helper observes the global
    # find pasteboard even when FindBar.HasGlobalFindPasteboard() is false.
    find_platform = "chrome/browser/ui/find_bar/find_bar_platform_helper_mac.mm"
    patch(find_platform, '#include <string_view>',
          '#include <string_view>\n#include "base/command_line.h"')
    patch(find_platform, '  return std::make_unique<FindBarPlatformHelperMac>(find_bar_controller);',
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '    return nullptr;  // Cio retains each tab query independently.\n'
          '  return std::make_unique<FindBarPlatformHelperMac>(find_bar_controller);')
    keychain = "components/os_crypt/common/keychain_password_mac.mm"
    patch(keychain, '#include <atomic>', '#include <atomic>\n#include "base/command_line.h"')
    patch(keychain, '  static KeychainNameContainerType service_name(kDefaultServiceName);',
          '  static KeychainNameContainerType service_name(\n'
          '      base::CommandLine::InitializedForCurrentProcess() &&\n'
          '      base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")\n'
          '          ? "Cio Safe Storage" : kDefaultServiceName);')
    patch(keychain, '  static KeychainNameContainerType account_name(kDefaultAccountName);',
          '  static KeychainNameContainerType account_name(\n'
          '      base::CommandLine::InitializedForCurrentProcess() &&\n'
          '      base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")\n'
          '          ? "Cio" : kDefaultAccountName);')
    exports = "chrome/app/framework.exports"
    patch(exports, '_ChromeMain\n', '_ChromeMain\n_CioNativeStart\n_CioNativeIsInitialized\n_CioNativeShutdown\n'
          '_CioNativePump\n_CioNativeFlushCookies\n_CioNativeSetDarkAppearance\n'
          '_CioNativePasswordSettings\n_CioNativeSetPasswordProvider\n_CioNativeRetryApplePasswords\n'
          '_OBJC_CLASS_$_BrowserBridge\n_OBJC_METACLASS_$_BrowserBridge\n'
          '_OBJC_CLASS_$_BrowserConnectionInfo\n_OBJC_METACLASS_$_BrowserConnectionInfo\n')
    patch(exports, '_ChromeMain\n',
          '_ChromeMain\n_OBJC_CLASS_$_CioExtensionInstallRequest\n'
          '_OBJC_METACLASS_$_CioExtensionInstallRequest\n')
    patch(exports, '_ChromeMain\n',
          '_ChromeMain\n_OBJC_CLASS_$_CioExtensionRemovalRequest\n'
          '_OBJC_METACLASS_$_CioExtensionRemovalRequest\n')

    patch("chrome/browser/ui/prefs/prefs_tab_helper.cc", "  WebPreferences pref_defaults;",
          '  registry->RegisterIntegerPref("cio.password_provider", 0);\n'
          '  registry->RegisterBooleanPref("cio.language_defaults_initialized", false);\n'
          "  WebPreferences pref_defaults;")
    patch("chrome/browser/profiles/profile_impl.cc",
          "bool ProfileImpl::ShouldRestoreOldSessionCookies() {",
          "bool ProfileImpl::ShouldRestoreOldSessionCookies() {\n"
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")) return true;')
    # A reinstall / repeated install notification can encounter a pin already
    # restored from prefs. SetActionVisibility requires a state transition;
    # preserve that invariant instead of pinning an already-pinned action.
    patch("chrome/browser/ui/toolbar/toolbar_actions_model.cc",
          '  if (is_pinned_by_policy || is_pinned_by_feature) {\n'
          '    SetActionVisibility(extension->id(), true);',
          '  if ((is_pinned_by_policy || is_pinned_by_feature) &&\n'
          '      !IsActionPinned(extension->id())) {\n'
          '    SetActionVisibility(extension->id(), true);')

    side_panel_util = "chrome/browser/ui/views/side_panel/extensions/extension_side_panel_utils.cc"
    patch(side_panel_util, '#include "chrome/browser/ui/extensions/extension_side_panel_utils.h"',
          '#include "chrome/browser/ui/extensions/extension_side_panel_utils.h"\n'
          '#include "build/build_config.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioExtensionPanelHooks.h"\n#endif')
    for signature, browser, toggle, close, contextual in (
        ('void ToggleExtensionSidePanel(BrowserWindowInterface* browser_window,\n                              const ExtensionId& extension_id) {', 'browser_window', True, False, False),
        ('void OpenGlobalExtensionSidePanel(BrowserWindowInterface& browser_window,\n                                  content::WebContents* web_contents,\n                                  const ExtensionId& extension_id) {', '&browser_window', False, False, False),
        ('void OpenContextualExtensionSidePanel(BrowserWindowInterface& browser_window,\n                                      content::WebContents& web_contents,\n                                      const ExtensionId& extension_id) {', '&browser_window', False, False, True),
        ('void CloseGlobalExtensionSidePanel(BrowserWindowInterface* browser_window,\n                                   const ExtensionId& extension_id) {', 'browser_window', False, True, False),
        ('void CloseContextualExtensionSidePanel(BrowserWindowInterface* browser_window,\n                                       content::WebContents* web_contents,\n                                       const ExtensionId& extension_id) {', 'browser_window', False, True, True),
    ):
        flags = ', '.join(str(flag).lower() for flag in (toggle, close, contextual))
        patch(side_panel_util, signature, signature + '\n#if BUILDFLAG(IS_MAC)\n'
              f'  if (cio::HandleExtensionSidePanel({browser}, extension_id, {flags})) return;\n'
              '#endif')

    action_api = "chrome/browser/extensions/api/extension_action/extension_action_api.cc"
    patch(action_api, '#include "chrome/browser/extensions/api/extension_action/extension_action_api.h"',
          '#include "chrome/browser/extensions/api/extension_action/extension_action_api.h"\n'
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioExtensionPanelHooks.h"\n#endif')
    signature = ('bool OpenPopupInBrowser(BrowserWindowInterface& browser,\n'
                 '                        const Extension& extension,\n'
                 '                        std::string* error,\n'
                 '                        ShowPopupCallback callback) {')
    patch(action_api, signature, signature + '\n#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::HandleExtensionPopup(&browser, extension.id(), &callback)) return true;\n'
          '#endif')

    install_dialog = "chrome/browser/ui/views/extensions/extension_install_dialog_view.cc"
    patch(install_dialog, '#include "chrome/browser/ui/views/extensions/extension_install_dialog_view.h"',
          '#include "chrome/browser/ui/views/extensions/extension_install_dialog_view.h"\n'
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioExtensionUI.h"\n#endif')
    patch(install_dialog,
          '  gfx::NativeWindow parent_window = show_params->GetParentWindow();',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowExtensionInstallPrompt(show_params, done_callback, prompt)) return;\n'
          '#endif\n'
          '  gfx::NativeWindow parent_window = show_params->GetParentWindow();')
    patch(install_dialog,
          '  constrained_window::CreateBrowserModalDialogViews(std::move(dialog),\n'
          '                                                    parent_window)\n'
          '      ->Show();',
          '  auto* widget = constrained_window::CreateBrowserModalDialogViews(\n'
          '      std::move(dialog), parent_window);\n'
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowExtensionInstallSheet(widget)) return;\n'
          '#endif\n'
          '  widget->Show();')

    uninstall_dialog = "chrome/browser/ui/extensions/extension_uninstall_dialog_impl.cc"
    patch(uninstall_dialog, '#include "chrome/browser/extensions/extension_uninstall_dialog.h"',
          '#include "chrome/browser/extensions/extension_uninstall_dialog.h"\n'
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioExtensionRemoval.h"\n#endif')
    patch(uninstall_dialog,
          '  return std::make_unique<ExtensionUninstallDialogImpl>(profile, parent,',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (auto dialog = cio::CreateExtensionUninstallDialog(profile, parent, delegate))\n'
          '    return dialog;\n'
          '#endif\n'
          '  return std::make_unique<ExtensionUninstallDialogImpl>(profile, parent,')

    extension_ui = "chrome/browser/ui/extensions/extension_install_ui_desktop.cc"
    patch(extension_ui, '#include "build/build_config.h"',
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioExtensionUI.h"\n#endif')
    patch(extension_ui, '  // Extensions aren\'t enabled by default in incognito so we confirm',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowExtensionInstalled(profile(), extension.get())) return;\n'
          '#endif\n\n'
          '  // Extensions aren\'t enabled by default in incognito so we confirm')
    patch(extension_ui, '  BrowserWindowInterface* const browser =',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowExtensionInstallError(error)) return;\n'
          '#endif\n\n'
          '  BrowserWindowInterface* const browser =')
    browser = "chrome/browser/ui/browser.cc"

    extension_tabs = "chrome/browser/extensions/open_tab_helper.cc"
    patch(extension_tabs, '#include "chrome/browser/extensions/open_tab_helper.h"',
          '#include "chrome/browser/extensions/open_tab_helper.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(extension_tabs, '  return new_contents;\n}',
          '#if BUILDFLAG(IS_MAC)\n'
          '  cio::AdoptExtensionTab(browser.GetBrowserForMigrationOnly(), new_contents, active);\n'
          '#endif\n\n  return new_contents;\n}')

    # Keep Chromium's protocol policy/gesture checks and launch implementation;
    # only replace its Views child-modal confirmation in the hosted AppKit shell.
    external_protocol = "chrome/browser/ui/views/external_protocol_dialog.cc"
    patch(external_protocol, '#include "build/build_config.h"',
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(external_protocol, '  // Windowing system takes ownership.',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowExternalProtocolDialog(web_contents, url, program_name,\n'
          '          initiating_origin, initiator_document)) return;\n'
          '#endif\n\n'
          '  // Windowing system takes ownership.')

    # Preserve Chromium's complete WebAuthn UI and security tracking, but use
    # an AppKit sheet instead of an invalid NativeWidgetMac child parent.
    auth_controller = "chrome/browser/ui/views/webauthn/authenticator_request_dialog_view_controller_views.cc"
    patch(auth_controller, '#include <utility>',
          '#include <utility>\n#include "build/build_config.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(auth_controller,
          '  widget_ = constrained_window::ShowWebModalDialogViewsOwned(\n'
          '      view_, web_contents, views::Widget::InitParams::CLIENT_OWNS_WIDGET);',
          '#if BUILDFLAG(IS_MAC)\n'
          '  widget_ = cio::CreateWebAuthnDialog(view_, web_contents);\n'
          '  if (!widget_)\n'
          '#endif\n'
          '  widget_ = constrained_window::ShowWebModalDialogViewsOwned(\n'
          '      view_, web_contents, views::Widget::InitParams::CLIENT_OWNS_WIDGET);')
    auth_view = "chrome/browser/ui/views/webauthn/authenticator_request_dialog_view.cc"
    patch(auth_view, '#include <memory>',
          '#include <memory>\n#include "build/build_config.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(auth_view, '\n  GetWidget()->Show();',
          '\n#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowWebAuthnDialog(GetWidget())) return;\n'
          '#endif\n  GetWidget()->Show();')
    patch(auth_view, '    GetWidget()->Show();', '    Show();')

    # Cio hosts WebContents in AppKit, so its native window deliberately has
    # no Views BrowserView. SadTabController uses this lookup on creation,
    # reinstallation and destruction; leave the overlay to Cio's existing
    # renderer-crash UI without entering the Chrome-only window invariant.
    sad_tab = "chrome/browser/ui/sad_tab_controller.cc"
    patch(sad_tab, '#include "chrome/browser/ui/sad_tab_controller.h"',
          '#include "chrome/browser/ui/sad_tab_controller.h"\n'
          '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioNativeRuntime.h"\n#endif')
    patch(sad_tab,
          'ContentsWebView* FindContentsWebView(content::WebContents* web_contents) {',
          'ContentsWebView* FindContentsWebView(content::WebContents* web_contents) {\n'
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::IsHostedBrowser()) return nullptr;\n'
          '#endif')

    # Native installers know standard Chrome/Chromium directories, not Cio's
    # custom user-data directory. Resolve their manifests without copying them
    # or changing origin, executable, enterprise-policy or host validation.
    native_hosts = "chrome/browser/extensions/api/messaging/launch_context_posix.cc"
    patch(native_hosts, '  if (result.empty()) {\n'
          '    error_message = "Can\'t find native messaging host " + host_name;',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (result.empty() && base::CommandLine::ForCurrentProcess()->\n'
          '      HasSwitch("cio-embedded-browser")) {\n'
          '    base::FilePath home;\n'
          '    if (allow_user_level_hosts && base::PathService::Get(base::DIR_HOME, &home)) {\n'
          '      for (const char* directory : {\n'
          '          "Library/Application Support/Chromium/NativeMessagingHosts",\n'
          '          "Library/Application Support/Google/Chrome/NativeMessagingHosts"}) {\n'
          '        auto candidate = home.Append(directory).Append(host_name + ".json");\n'
          '        if (base::PathExists(candidate)) { result = candidate; break; }\n'
          '      }\n'
          '    }\n'
          '    if (result.empty()) {\n'
          '      auto candidate = base::FilePath("/Library/Google/Chrome/NativeMessagingHosts")\n'
          '          .Append(host_name + ".json");\n'
          '      if (base::PathExists(candidate)) result = candidate;\n'
          '    }\n'
          '  }\n'
          '#endif\n\n'
          '  if (result.empty()) {\n'
          '    error_message = "Can\'t find native messaging host " + host_name;')

    permissions = "chrome/browser/ui/views/permissions/permission_prompt_factory.cc"
    patch(permissions, '#include "chrome/browser/ui/permission_bubble/permission_prompt.h"',
          '#include "chrome/browser/ui/permission_bubble/permission_prompt.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioNativeRuntime.h"\n'
          '#include "chrome/browser/ui/cio/CioPermissions.h"\n#endif')
    patch(permissions, '  if (delegate->ShouldDropCurrentRequestIfCannotShowQuietly() &&',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::IsHostedBrowser()) return cio::CreatePermissionPrompt(web_contents, delegate);\n'
          '#endif\n  if (delegate->ShouldDropCurrentRequestIfCannotShowQuietly() &&')
    media_picker = "chrome/browser/ui/views/media_picker_utils.cc"
    patch(media_picker, '#include "ui/views/window/dialog_delegate.h"',
          '#include "ui/views/window/dialog_delegate.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(media_picker, '  // If |web_contents| is not a background page then the picker will be shown',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (auto* hosted = cio::CreateMediaPickerDialog(delegate, web_contents)) return hosted;\n'
          '#endif\n  // If |web_contents| is not a background page then the picker will be shown')

    # Password UI is hosted per WebContents; retain the upstream model,
    # suggestion delegates, save/update controller, generation and auth paths.
    from cio_password_overlay import prepare_password_overlay
    prepare_password_overlay(patch)

    patch(browser, '#include "chrome/browser/ui/browser.h"',
          '#include "chrome/browser/ui/browser.h"\n#if BUILDFLAG(IS_MAC)\n'
          '#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(browser, '  return javascript_dialogs::TabModalDialogManager::FromWebContents(source);',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (auto* dialogs = cio::NativeJavaScriptDialogs()) return dialogs;\n#endif\n'
          '  return javascript_dialogs::TabModalDialogManager::FromWebContents(source);')
    patch(browser, '    base::RepeatingClosure hang_monitor_restarter) {',
          '    base::RepeatingClosure hang_monitor_restarter) {\n#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::ShowHungRenderer(source, hang_monitor_restarter)) return;\n#endif')
    patch(browser, 'void Browser::RendererResponsive(\n'
          '    WebContents* source,\n'
          '    content::RenderWidgetHost* render_widget_host) {',
          'void Browser::RendererResponsive(\n'
          '    WebContents* source,\n'
          '    content::RenderWidgetHost* render_widget_host) {\n#if BUILDFLAG(IS_MAC)\n'
          '  if (cio::HideHungRenderer(source)) return;\n#endif')
    patch(browser, '  TRACE_EVENT1("navigation", "Browser::OpenURLFromTab", "source", source);',
          '  TRACE_EVENT1("navigation", "Browser::OpenURLFromTab", "source", source);\n'
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (params.disposition != WindowOpenDisposition::CURRENT_TAB &&\n'
          '      params.disposition != WindowOpenDisposition::SAVE_TO_DISK &&\n'
          '      cio::OpenNewTab(this, params.url)) return nullptr;\n#endif')
    patch(browser, '    bool* was_blocked) {',
          '    bool* was_blocked) {\n#if BUILDFLAG(IS_MAC)\n'
          '  auto* cio_popup = new_contents.get();\n'
          '  if (cio::AdoptPopup(this, new_contents, target_url)) {\n'
          '    if (was_blocked) *was_blocked = false;\n'
          '    return cio_popup;\n  }\n#endif')
    downloads = "chrome/browser/download/chrome_download_manager_delegate.cc"
    patch(downloads, '#include "chrome/browser/download/chrome_download_manager_delegate.h"',
          '#include "chrome/browser/download/chrome_download_manager_delegate.h"\n'
          '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/cio/CioWindowHooks.h"\n#endif')
    patch(downloads, '      GetPlatformDownloadPath(download, PLATFORM_TARGET_PATH);',
          '      GetPlatformDownloadPath(download, PLATFORM_TARGET_PATH);\n'
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")) {\n'
          '    auto selected_path = cio::DownloadPath(download);\n'
          '    if (selected_path) {\n'
          '      if (selected_path->empty()) {\n'
          '        download::DownloadTargetInfo failure;\n'
          '        failure.interrupt_reason = download::DOWNLOAD_INTERRUPT_REASON_FILE_ACCESS_DENIED;\n'
          '        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(\n'
          '            FROM_HERE, base::BindOnce(std::move(target_determined_callback),\n'
          '                std::move(failure), safe_browsing::DownloadFileType::NOT_DANGEROUS));\n'
          '        return true;\n'
          '      }\n'
          '      download_path = *selected_path;\n'
          '    }\n'
          '  }\n#endif')
    devtools = "chrome/browser/devtools/devtools_window.cc"
    patch(devtools, '    if (!devtools_ui_controller || !devtools_ui_controller->CanDockDevtools()) {\n'
          '      can_dock = false;\n    }',
          '    if (!devtools_ui_controller || !devtools_ui_controller->CanDockDevtools()) {\n'
          '      can_dock = false;\n    }\n'
          '#if BUILDFLAG(IS_MAC)\n'
          '    if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '      can_dock = true;  // Cio supplies the native inspector host.\n'
          '#endif')
    patch(devtools, '  bool was_docked = is_docked_;',
          '#if BUILDFLAG(IS_MAC)\n'
          '  if (can_dock_ && base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser"))\n'
          '    dock_requested = true;  // Cio owns any separate inspector window.\n#endif\n'
          '  bool was_docked = is_docked_;')
    determiner = "chrome/browser/download/download_target_determiner.cc"
    patch(determiner, '#include "chrome/browser/download/download_target_determiner.h"',
          '#include "chrome/browser/download/download_target_determiner.h"\n'
          '#include "base/command_line.h"')
    patch(determiner, '    should_notify_extensions_ = true;\n'
          '    virtual_path_ = target_directory.Append(generated_filename);',
          '#if BUILDFLAG(IS_MAC)\n'
          '    // Honor the shell-selected destination while retaining Chromium\n'
          '    // confirmation, managed-path, reservation and safety checks.\n'
          '    if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser") &&\n'
          '        !virtual_path_.empty() &&\n'
          '        confirmation_reason_ == DownloadConfirmationReason::NONE &&\n'
          '        !download_prefs_->IsDownloadPathManaged()) {\n'
          '      target_directory = virtual_path_.DirName();\n'
          '      generated_filename = virtual_path_.BaseName();\n'
          '    }\n#endif\n'
          '    should_notify_extensions_ = true;\n'
          '    virtual_path_ = target_directory.Append(generated_filename);')
    for relative, text in PATCHES.items():
        path = SOURCE / relative
        if path.read_text() != text:
            path.write_text(text)

def main():
    lock = (ROOT / "build/ChromiumBuild/attempt.lock").open("a+")
    fcntl.flock(lock, fcntl.LOCK_EX)
    prepare()
    attempt = Attempt(SimpleNamespace(jobs=4, minimum_free_gib=20))
    def stop(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        attempt.run("native-generate", [str(SOURCE / "buildtools/mac/gn"), "gen", "out/CioDev"], SOURCE)
        attempt.run("native-compile", ["caffeinate", "-i", str(SOURCE / "third_party/ninja/ninja"),
                                      "-C", "out/CioDev", "-j", "4", "chrome"], SOURCE)
        binaries = SOURCE / "out/CioDev"
        metadata = {
            "version": VERSION, "source_sha256": SOURCE_SHA256,
            "native_backend_built": True, "integrated_in_cio": False,
            "overlay": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                        for directory in ("Native", "Public")
                        for p in (ROOT / "Engine/CioChromium" / directory).iterdir() if p.is_file()},
        }
        (binaries / "cio-native-build.json").write_text(json.dumps(metadata, indent=2) + "\n")
        attempt.record("success", native_backend_built=True)
    except (Exception, KeyboardInterrupt) as error:
        attempt.record("failed", error=str(error))
        raise
    return 0

if __name__ == "__main__":
    sys.exit(main())
