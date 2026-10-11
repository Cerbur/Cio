#include "chrome/browser/ui/cio/CioTabExtensions.h"
#import "chrome/browser/ui/cio/BrowserBridge.h"

#include <map>
#include <algorithm>
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/extensions/api/side_panel/side_panel_service.h"
#include "chrome/browser/extensions/extension_action_dispatcher.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/extensions/extension_view_host_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/extensions/extension_action_delegate.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/manifest.h"
#include "ui/base/models/image_model.h"
#include "ui/gfx/image/image.h"

// AppKit owns dismissal. Destruction is posted back to Chromium's UI sequence
// so neither a renderer callback nor an AppKit delegate deletes its own stack.
@interface CioExtensionSurfaceTarget : NSObject <NSPopoverDelegate>
@property(nonatomic, copy) void (^closeSurface)(void);
- (void)close:(id)sender;
@end
@implementation CioExtensionSurfaceTarget
@synthesize closeSurface = _closeSurface;
- (void)close:(id)sender { if (self.closeSurface) self.closeSurface(); }
- (void)popoverDidClose:(NSNotification*)notification { [self close:nil]; }
@end

namespace cio {
namespace {
std::map<Browser*, TabExtensions*>& Controllers() {
  static auto* controllers = new std::map<Browser*, TabExtensions*>;
  return *controllers;
}

// A real ExtensionViewHost, with the same view type as Chrome's popup or
// side panel. Navigating an ordinary tab to an extension URL cannot substitute
// for this: it would have different API scope and host lifecycle.
class NativeExtensionSurface final : public extensions::ExtensionView {
 public:
  NativeExtensionSurface(std::unique_ptr<extensions::ExtensionViewHost> host,
                         NSView* container, NSPopover* popover,
                         ShowPopupCallback callback = ShowPopupCallback())
      : host_(std::move(host)), popover_(popover), callback_(std::move(callback)) {
    host_->set_view(this);
    NSView* view = host_->host_contents()->GetNativeView().GetNativeNSView();
    view.frame = container.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:view];
  }
  ~NativeExtensionSurface() override {
    if (callback_) std::move(callback_).Run(nullptr);
    [host_->host_contents()->GetNativeView().GetNativeNSView() removeFromSuperview];
    host_->set_view(nullptr);
  }
  extensions::ExtensionViewHost* host() { return host_.get(); }
  gfx::NativeView GetNativeView() override {
    return host_->host_contents()->GetNativeView();
  }
  void ResizeDueToAutoResize(content::WebContents*, const gfx::Size& size) override {
    if (popover_) popover_.contentSize = NSMakeSize(size.width(), size.height());
  }
  void RenderFrameCreated(content::RenderFrameHost* frame) override {
    if (popover_ && frame == host_->host_contents()->GetPrimaryMainFrame()) {
      if (auto* view = host_->host_contents()->GetRenderWidgetHostView())
        view->EnableAutoResize(gfx::Size(25, 25), gfx::Size(800, 600));
    }
  }
  bool HandleKeyboardEvent(content::WebContents*,
                           const input::NativeWebKeyboardEvent&) override {
    return false;
  }
  void OnLoaded() override {
    // The initial main frame can predate set_view(), or its widget may not
    // exist in RenderFrameCreated. Enable sizing once the popup is loaded too.
    if (popover_) {
      if (auto* widget = host_->host_contents()->GetRenderWidgetHostView())
        widget->EnableAutoResize(gfx::Size(25, 25), gfx::Size(800, 600));
    }
    NSView* view = GetNativeView().GetNativeNSView();
    if (view.window && !view.isHiddenOrHasHiddenAncestor) host_->host_contents()->Focus();
    if (callback_) std::move(callback_).Run(host_.get());
  }
 private:
  std::unique_ptr<extensions::ExtensionViewHost> host_;
  __weak NSPopover* popover_;
  ShowPopupCallback callback_;
};
}

class TabExtensions::Impl final : public extensions::ExtensionRegistryObserver,
                                 public extensions::ExtensionActionDispatcher::Observer,
                                 public extensions::SidePanelService::Observer {
 public:
  class ActionDelegate final : public ExtensionActionDelegate {
   public:
    explicit ActionDelegate(Impl* owner) : owner_(owner) {}
    void AttachToModel(ExtensionActionViewModel* model) override { model_ = model; }
    void DetachFromModel() override { model_ = nullptr; }
    void RegisterCommand() override {}
    void UnregisterCommand() override {}
    bool IsShowingPopup() const override {
      return owner_->popup_ && owner_->popup_->host()->extension_id() == model_->GetId();
    }
    void HidePopup() override { owner_->ClosePopup(); }
    gfx::NativeView GetPopupNativeViewForTesting() override {
      return IsShowingPopup() ? owner_->popup_->GetNativeView() : gfx::NativeView();
    }
    void TriggerPopup(std::unique_ptr<extensions::ExtensionViewHost> host,
                      PopupShowAction, bool, ShowPopupCallback callback) override {
      owner_->ShowPopup(std::move(host), std::move(callback));
    }
    void ShowContextMenuAsFallback() override { owner_->OpenManager(); }
    void CloseExtensionsMenuIfOpen() override {}
   private:
    raw_ptr<Impl> owner_;
    raw_ptr<ExtensionActionViewModel> model_ = nullptr;
  };
  struct Action {
    std::unique_ptr<ExtensionActionViewModel> model;
    base::CallbackListSubscription icon_subscription;
  };

  Impl(Browser* browser, content::WebContents* contents, BrowserBridge* bridge)
      : browser_(browser), contents_(contents), bridge_(bridge) {
    registry_ = extensions::ExtensionRegistry::Get(browser->GetProfile());
    dispatcher_ = extensions::ExtensionActionDispatcher::Get(browser->GetProfile());
    panels_ = extensions::SidePanelService::Get(browser->GetProfile());
    registry_->AddObserver(this);
    dispatcher_->AddObserver(this);
    panels_->AddObserver(this);
    RefreshActions();
  }
  ~Impl() override {
    weak_factory_.InvalidateWeakPtrs();
    ClosePopup();
    ClosePanel();
    actions_.clear();
    if (registry_) registry_->RemoveObserver(this);
    if (dispatcher_) dispatcher_->RemoveObserver(this);
    if (panels_) panels_->RemoveObserver(this);
  }

  void Notify() {
    // Coalesce callbacks, including asynchronous icon decoding, and let Swift
    // observe a committed Chromium state rather than a registry mutation stack.
    if (notify_pending_) return;
    notify_pending_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Impl> self) {
          if (!self) return;
          self->notify_pending_ = false;
          [self->bridge_.delegate browserBridgeDidChangeExtensions:self->bridge_];
        }, weak_factory_.GetWeakPtr()));
  }
  void RefreshActions() {
    for (auto it = actions_.begin(); it != actions_.end();) {
      if (!registry_->enabled_extensions().Contains(it->first)) it = actions_.erase(it);
      else ++it;
    }
    for (const auto& extension : registry_->enabled_extensions()) {
      if (extensions::Manifest::IsComponentLocation(extension->location()) ||
          actions_.contains(extension->id()) ||
          !extensions::ExtensionActionManager::Get(browser_->GetProfile())->GetExtensionAction(*extension)) continue;
      Action action;
      action.model = ExtensionActionViewModel::Create(extension->id(), browser_,
          std::make_unique<ActionDelegate>(this));
      action.icon_subscription = action.model->RegisterIconUpdateObserver(
          base::BindRepeating(&Impl::Notify, weak_factory_.GetWeakPtr()));
      actions_.emplace(extension->id(), std::move(action));
    }
    Notify();
  }
  NSArray<NSDictionary<NSString*, id>*>* Snapshot() {
    NSMutableArray* result = [NSMutableArray array];
    for (auto& [id, action] : actions_) {
      auto* model = action.model.get();
      NSImage* icon = model->GetIcon(contents_, gfx::Size(32, 32)).GetImage().AsNSImage();
      NSData* png = nil;
      if (icon.TIFFRepresentation) {
        auto* rep = [NSBitmapImageRep imageRepWithData:icon.TIFFRepresentation];
        png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      }
      [result addObject:@{@"id":base::SysUTF8ToNSString(id),
                         @"name":base::SysUTF16ToNSString(model->GetActionName()),
                         @"title":base::SysUTF16ToNSString(model->GetTooltip(contents_)),
                         @"enabled":@(model->IsEnabled(contents_)),
                         @"icon":png ?: NSData.data}];
    }
    return result;
  }
  void Execute(NSString* id) {
    auto it = actions_.find(base::SysNSStringToUTF8(id));
    if (it != actions_.end())
      it->second.model->ExecuteUserAction(ToolbarActionViewModel::InvocationSource::kMenuEntry);
  }
  void OpenManager() {
    [bridge_.delegate browserBridge:bridge_ didRequestNewTabWithURL:@"chrome://extensions/"];
  }
  void ClosePopup() {
    ++popup_generation_;
    popover_.delegate = nil;
    [popover_ close];
    popup_.reset();
    popover_ = nil;
    popup_target_ = nil;
    [bridge_ setFocus:YES];
  }
  void ShowPopup(std::unique_ptr<extensions::ExtensionViewHost> host, ShowPopupCallback callback) {
    ClosePopup();
    if (!parent_.window || parent_.isHiddenOrHasHiddenAncestor) {
      if (callback) base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(std::move(callback), nullptr));
      return;
    }
    popover_ = [[NSPopover alloc] init];
    popover_.behavior = NSPopoverBehaviorTransient;
    popover_.contentSize = NSMakeSize(360, 280);
    NSViewController* controller = [[NSViewController alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 280)];
    popover_.contentViewController = controller;
    popup_target_ = [[CioExtensionSurfaceTarget alloc] init];
    auto weak = weak_factory_.GetWeakPtr();
    auto generation = popup_generation_;
    popup_target_.closeSurface = ^{
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce([](base::WeakPtr<Impl> self, uint64_t expected_generation) {
            if (self && self->popup_generation_ == expected_generation) self->ClosePopup();
          }, weak, generation));
    };
    popover_.delegate = popup_target_;
    popup_ = std::make_unique<NativeExtensionSurface>(std::move(host), controller.view, popover_, std::move(callback));
    popup_->host()->SetCloseHandler(base::BindOnce(
        [](base::WeakPtr<Impl> self, extensions::ExtensionHost*) {
          if (self) [self->popup_target_ close:nil];
        }, weak));
    // Anchor to the owning pane's top edge; the site information menu has
    // already returned to its resting address capsule before focus is taken.
    // AppKit won't show a popover whose anchor lies outside its view. Keep
    // the entire rect inside the top edge, including for flipped hosts.
    CGFloat top = parent_.isFlipped ? NSMinY(parent_.bounds) : NSMaxY(parent_.bounds) - 1;
    [popover_ showRelativeToRect:NSMakeRect(NSMidX(parent_.bounds), top, 1, 1)
                         ofView:parent_ preferredEdge:NSRectEdgeMinY];
    if (!popover_.shown) {
      [popup_target_ close:nil];
      return;
    }
    popup_->host()->host_contents()->WasShown();
    popup_->host()->CreateRendererSoon();
  }
  void ShowPanel(const std::string& id, bool toggle, bool contextual) {
    if (toggle) {
      const auto* extension = registry_->enabled_extensions().GetByID(id);
      if (extension) {
        auto specific = panels_->GetSpecificOptionsForTab(*extension,
            sessions::SessionTabHelper::IdForTab(contents_).id());
        contextual = specific.path.has_value() && specific.enabled.value_or(false);
      }
    }
    const auto* extension = registry_->enabled_extensions().GetByID(id);
    if (!extension || !panels_) return;
    int tab_id = sessions::SessionTabHelper::IdForTab(contents_).id();
    auto options = panels_->GetOptions(*extension, contextual ? std::optional<int>(tab_id) : std::nullopt);
    if (!options.enabled.value_or(false) || !options.path || options.path->empty()) return;
    auto scoped_tab = contextual ? std::optional<int>(tab_id) : std::nullopt;
    if (panel_ && panel_->host()->extension_id() == id &&
        panel_path_ == *options.path && panel_tab_ == scoped_tab) {
      if (toggle) ClosePanel();
      return;
    }
    auto host = extensions::ExtensionViewHostFactory::CreateSidePanelHost(
        *extension, extension->GetResourceURL(*options.path),
        contextual ? nullptr : browser_.get(),
        contextual ? browser_->GetActiveTabInterface() : nullptr);
    if (!host) return;
    ClosePanel();
    panel_path_ = *options.path;
    panel_tab_ = contextual ? std::optional<int>(tab_id) : std::nullopt;
    panel_container_ = [[NSView alloc] init];
    panel_container_.wantsLayer = YES;
    panel_container_.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    NSTextField* title = [NSTextField labelWithString:base::SysUTF8ToNSString(extension->name())];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(12, 0, 260, 20);
    title.autoresizingMask = NSViewMinYMargin;
    [panel_container_ addSubview:title];
    panel_title_ = title;
    panel_target_ = [[CioExtensionSurfaceTarget alloc] init];
    auto weak = weak_factory_.GetWeakPtr();
    auto generation = ++panel_generation_;
    panel_target_.closeSurface = ^{
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce([](base::WeakPtr<Impl> self, uint64_t expected_generation) {
            if (self && self->panel_generation_ == expected_generation) self->ClosePanel();
          }, weak, generation));
    };
    NSButton* close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"关闭扩展侧栏"]
                                       target:panel_target_ action:@selector(close:)];
    close.bordered = NO;
    close.frame = NSMakeRect(0, 0, 28, 28);
    [panel_container_ addSubview:close];
    panel_close_ = close;
    panel_content_ = [[NSView alloc] init];
    [panel_container_ addSubview:panel_content_];
    [parent_ addSubview:panel_container_];
    panel_ = std::make_unique<NativeExtensionSurface>(std::move(host), panel_content_, nil);
    panel_->host()->SetCloseHandler(base::BindOnce(
        [](base::WeakPtr<Impl> self, extensions::ExtensionHost*) {
          if (self) [self->panel_target_ close:nil];
        }, weak));
    [bridge_ resizeToBounds:parent_.bounds];
    UpdateVisibility();
    panel_->host()->CreateRendererSoon();
    panels_->DispatchOnOpenedEvent(id, browser_->session_id().id(), panel_tab_, panel_path_);
  }
  void ClosePanel() {
    if (!panel_) return;
    ++panel_generation_;
    if (panels_) panels_->DispatchOnClosedEvent(panel_->host()->extension_id(),
        browser_->session_id().id(), panel_tab_, panel_path_);
    panel_.reset();
    [panel_container_ removeFromSuperview];
    panel_container_ = nil;
    panel_target_ = nil;
    [bridge_ resizeToBounds:parent_.bounds];
    [bridge_ setFocus:YES];
  }
  NSRect Layout(NSRect bounds) {
    if (!panel_) return bounds;
    CGFloat width = std::min<CGFloat>(380, bounds.size.width * 0.5);
    panel_container_.frame = NSMakeRect(NSMaxX(bounds) - width, 0, width, bounds.size.height);
    panel_title_.frame = NSMakeRect(12, bounds.size.height - 30, width - 52, 20);
    panel_close_.frame = NSMakeRect(width - 34, bounds.size.height - 34, 28, 28);
    panel_content_.frame = NSMakeRect(1, 0, width - 1, std::max<CGFloat>(0, bounds.size.height - 38));
    return NSMakeRect(0, 0, bounds.size.width - width, bounds.size.height);
  }
  void Reparent(NSView* parent) {
    parent_ = parent;
    if (panel_container_.superview != parent && panel_container_) [parent addSubview:panel_container_];
    UpdateVisibility();
  }
  void UpdateVisibility() {
    const bool hidden = !parent_.window || parent_.isHiddenOrHasHiddenAncestor;
    if (hidden && popup_) ClosePopup();
    if (panel_) {
      auto* contents = panel_->host()->host_contents();
      if (hidden && contents->GetVisibility() == content::Visibility::VISIBLE) contents->WasHidden();
      else if (!hidden && contents->GetVisibility() == content::Visibility::HIDDEN) contents->WasShown();
    }
  }
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension*) override { RefreshActions(); }
  void OnExtensionReady(content::BrowserContext*, const extensions::Extension*) override { RefreshActions(); }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason) override {
    if (popup_ && popup_->host()->extension_id() == extension->id()) ClosePopup();
    if (panel_ && panel_->host()->extension_id() == extension->id()) ClosePanel();
    RefreshActions();
  }
  void OnShutdown(extensions::ExtensionRegistry*) override { registry_ = nullptr; }
  void OnShuttingDown() override { dispatcher_ = nullptr; }
  void OnExtensionActionUpdated(extensions::ExtensionAction*, content::WebContents* contents,
                                content::BrowserContext*) override {
    if (!contents || contents == contents_) Notify();
  }
  void OnPanelOptionsChanged(const std::string& id,
                             const extensions::api::side_panel::PanelOptions& options) override {
    Notify();
    if (panel_ && panel_->host()->extension_id() == id &&
        (!options.tab_id || options.tab_id == sessions::SessionTabHelper::IdForTab(contents_).id())) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce([](base::WeakPtr<Impl> self, std::string changed_id) {
            if (!self || !self->panel_ || self->panel_->host()->extension_id() != changed_id || !self->panels_) return;
            const auto* extension = self->registry_->enabled_extensions().GetByID(changed_id);
            if (!extension) return;
            auto updated = self->panels_->GetOptions(*extension, self->panel_tab_);
            if (updated.enabled.value_or(false) && updated.path == self->panel_path_) return;
            bool contextual = self->panel_tab_.has_value();
            self->ClosePanel();
            self->ShowPanel(changed_id, false, contextual);
          }, weak_factory_.GetWeakPtr(), id));
    }
  }
  void OnSidePanelServiceShutdown() override { panels_ = nullptr; }

  raw_ptr<Browser> browser_;
  raw_ptr<content::WebContents> contents_;
  __weak BrowserBridge* bridge_;
  __weak NSView* parent_;
  raw_ptr<extensions::ExtensionRegistry> registry_;
  raw_ptr<extensions::ExtensionActionDispatcher> dispatcher_;
  raw_ptr<extensions::SidePanelService> panels_;
  std::map<std::string, Action> actions_;
  std::unique_ptr<NativeExtensionSurface> popup_, panel_;
  NSPopover* popover_;
  CioExtensionSurfaceTarget* popup_target_;
  NSView* panel_container_;
  NSView* panel_content_;
  NSTextField* panel_title_;
  NSButton* panel_close_;
  CioExtensionSurfaceTarget* panel_target_;
  std::string panel_path_;
  std::optional<int> panel_tab_;
  bool notify_pending_ = false;
  uint64_t popup_generation_ = 0;
  uint64_t panel_generation_ = 0;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

TabExtensions::TabExtensions(Browser* browser, content::WebContents* contents, BrowserBridge* bridge)
    : impl_(std::make_unique<Impl>(browser, contents, bridge)) { Controllers()[browser] = this; }
TabExtensions::~TabExtensions() { Controllers().erase(impl_->browser_); }
NSArray<NSDictionary<NSString*, id>*>* TabExtensions::Snapshot() { return impl_->Snapshot(); }
void TabExtensions::Execute(NSString* id) { impl_->Execute(id); }
void TabExtensions::ShowPanel(const std::string& id, bool toggle, bool contextual) { impl_->ShowPanel(id, toggle, contextual); }
void TabExtensions::ClosePanel(const std::string& id) {
  if (impl_->panel_ && impl_->panel_->host()->extension_id() == id) impl_->ClosePanel();
}
void TabExtensions::Reparent(NSView* parent) { impl_->Reparent(parent); }
NSRect TabExtensions::Layout(NSRect bounds) { return impl_->Layout(bounds); }
void TabExtensions::ClosePopup() { impl_->ClosePopup(); }
bool TabExtensions::HasPopup() const { return impl_->popup_ != nullptr; }
void TabExtensions::UpdateVisibility() { impl_->UpdateVisibility(); }
void TabExtensions::TriggerPopupForAPI(const std::string& id, ShowPopupCallback callback) {
  auto it = impl_->actions_.find(id);
  if (it != impl_->actions_.end()) it->second.model->TriggerPopupForAPI(std::move(callback));
  else if (callback) base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(callback), nullptr));
}
bool HandleExtensionSidePanel(BrowserWindowInterface* browser, const std::string& id,
                              bool toggle, bool close, bool contextual) {
  auto it = Controllers().find(browser->GetBrowserForMigrationOnly());
  if (it == Controllers().end()) return false;
  if (close) it->second->ClosePanel(id);
  else it->second->ShowPanel(id, toggle, contextual);
  return true;
}
bool HandleExtensionPopup(BrowserWindowInterface* browser, const std::string& id,
                          ShowPopupCallback* callback) {
  auto it = Controllers().find(browser->GetBrowserForMigrationOnly());
  if (it == Controllers().end()) return false;
  it->second->TriggerPopupForAPI(id, std::move(*callback));
  return true;
}
}
