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
          '_OBJC_CLASS_$_BrowserBridge\n_OBJC_METACLASS_$_BrowserBridge\n'
          '_OBJC_CLASS_$_BrowserConnectionInfo\n_OBJC_METACLASS_$_BrowserConnectionInfo\n')

    patch("chrome/browser/ui/prefs/prefs_tab_helper.cc", "  WebPreferences pref_defaults;",
          '  registry->RegisterBooleanPref("cio.language_defaults_initialized", false);\n'
          "  WebPreferences pref_defaults;")
    patch("chrome/browser/profiles/profile_impl.cc",
          "bool ProfileImpl::ShouldRestoreOldSessionCookies() {",
          "bool ProfileImpl::ShouldRestoreOldSessionCookies() {\n"
          '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("cio-embedded-browser")) return true;')
    browser = "chrome/browser/ui/browser.cc"
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
          '    if (!selected_path.empty()) download_path = selected_path;\n'
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
