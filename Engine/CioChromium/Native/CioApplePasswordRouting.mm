#include "chrome/browser/ui/cio/CioPasswords.h"
#include <atomic>
#include <map>
#include <mutex>
#include <tuple>
#include <vector>
#include "base/json/json_reader.h"
#include "base/values.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "extensions/browser/extension_api_frame_id_map.h"

namespace cio {
namespace {
// Apple's v3.4.0 envelope routes these commands by (cmd, tabId, frameId).
// Only routing metadata is retained. Pairing, payload/SMSG, passwords and OTPs
// are opaque to the host and are never persisted, displayed or logged.
using RouteKey = std::tuple<int, int, int>;
std::optional<RouteKey> Route(const std::string& message) {
  auto json = base::JSONReader::Read(message, base::JSON_PARSE_RFC);
  if (!json || !json->is_dict()) return std::nullopt;
  const auto& value = json->GetDict();
  auto cmd = value.FindInt("cmd");
  auto tab = value.FindInt("tabId");
  auto frame = value.FindInt("frameId");
  if (!cmd || !tab || !frame) return std::nullopt;
  if (*cmd != 4 && *cmd != 5 && *cmd != 16) return std::nullopt;
  return std::make_tuple(*cmd, *tab, *frame);
}
class AppleRequest final : public content::WebContentsObserver {
 public:
  AppleRequest(content::WebContents* contents, content::RenderFrameHost* frame)
      : WebContentsObserver(contents), primary_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        frame_(frame->GetWeakDocumentPtr()) {}
  PasswordRouteLease lease;
  bool Valid(bool foreground = false) const {
    return !cancelled_ && primary_.AsRenderFrameHostIfValid() && frame_.AsRenderFrameHostIfValid() &&
        (!foreground || CanPresentPasswordUI(web_contents()));
  }
  void Cancel() { cancelled_ = true; lease.Cancel(); }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() || handle->GetRenderFrameHost() == frame_.AsRenderFrameHostIfValid()) Cancel();
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) Cancel();
  }
  void WebContentsDestroyed() override { Cancel(); }
 private:
  bool cancelled_ = false;
  content::WeakDocumentPtr primary_;
  content::WeakDocumentPtr frame_;
};
std::mutex& RegistryLock() { static auto* value = new std::mutex; return *value; }
std::map<void*, std::shared_ptr<ApplePasswordRouting>>& Registry() {
  static auto* value = new std::map<void*, std::shared_ptr<ApplePasswordRouting>>; return *value;
}
}
class ApplePasswordRouting {
 public:
  std::atomic<uint64_t> epoch{0};
  bool Capture(const std::string& message) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto key = Route(message);
    if (!key) return true;
    auto* contents = PasswordContentsForExtensionTab(std::get<1>(*key));
    auto* frame = contents ? extensions::ExtensionApiFrameIdMap::GetRenderFrameHostById(contents, std::get<2>(*key)) : nullptr;
    if (!frame || (std::get<0>(*key) == 5 && !CanPresentPasswordUI(contents))) return Pause();
    auto found = pending_.find(*key);
    if (found != pending_.end() && !found->second->Valid()) return Pause();
    // Several same-document queries can be in flight. They share one immutable
    // target; never overwrite a revoked target with a newer document.
    if (found == pending_.end()) pending_[*key] = std::make_unique<AppleRequest>(contents, frame);
    if (!pending_[*key]->lease.Request(true)) return Pause();
    return true;
  }
  bool Accept(const std::string& message) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto key = Route(message);
    if (!key) return true;
    auto found = pending_.find(*key);
    if (found == pending_.end() || !found->second->Valid(std::get<0>(*key) == 5)) return Pause();
    // Pending requests for the same key may complete in any order, but all
    // have the same document. A new document cannot replace a pending target.
    if (!found->second->lease.Respond(true)) return Pause();
    if (found->second->lease.idle()) pending_.erase(found);
    return true;
  }
  void Cancel(content::WebContents* contents) {
    for (auto& [key, request] : pending_)
      if (request->web_contents() == contents && std::get<0>(key) == 5) request->Cancel();
  }
 private:
  bool Pause() {
    AppleConnectionFailed(epoch.load(), "Cio canceled an obsolete iCloud Passwords request after page or pane changed.");
    return false;
  }
  std::map<RouteKey, std::unique_ptr<AppleRequest>> pending_;
};
void RegisterApplePasswordHost(void* host) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto routing = std::shared_ptr<ApplePasswordRouting>(new ApplePasswordRouting,
      [](ApplePasswordRouting* value) { content::GetUIThreadTaskRunner({})->DeleteSoon(FROM_HERE, value); });
  std::lock_guard<std::mutex> lock(RegistryLock());
  Registry()[host] = std::move(routing);
}
void UnregisterApplePasswordHost(void* host) {
  std::lock_guard<std::mutex> lock(RegistryLock());
  Registry().erase(host);
}
std::shared_ptr<ApplePasswordRouting> AppleRoutingForHost(void* host) {
  std::lock_guard<std::mutex> lock(RegistryLock());
  auto found = Registry().find(host);
  return found == Registry().end() ? nullptr : found->second;
}
void ApplePasswordHostBegan(void* host, uint64_t epoch) {
  if (auto routing = AppleRoutingForHost(host)) routing->epoch.store(epoch);
}
bool CaptureApplePasswordRequest(const std::shared_ptr<ApplePasswordRouting>& routing, const std::string& message) {
  return !routing || routing->Capture(message);
}
bool AcceptApplePasswordResponse(const std::shared_ptr<ApplePasswordRouting>& routing, const std::string& message) {
  return !routing || routing->Accept(message);
}
void CancelApplePasswordRequests(content::WebContents* contents) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  std::vector<std::shared_ptr<ApplePasswordRouting>> routes;
  {
    std::lock_guard<std::mutex> lock(RegistryLock());
    for (auto& [host, routing] : Registry()) routes.push_back(routing);
  }
  for (auto& routing : routes) routing->Cancel(contents);
}
}
