#include "Engine/CioChromium/Native/CioPasswordPolicy.h"
#include <cstdlib>
#include <iostream>
#include <functional>
#include <thread>
#include <vector>

namespace {
int checks = 0;
void Check(bool result, const char* label) {
  ++checks;
  if (!result) { std::cerr << "FAIL: " << label << '\n'; std::exit(1); }
}
struct FakePane {
  uint64_t document = 1;
  bool selected = true;
  bool enabled = true;
  int writes = 0;
};
// A synthetic callback queue exercises the production request admission rule.
// No WebContents, password store, Keychain or system Apple process is opened.
std::function<void()> Request(FakePane& pane, cio::PasswordRequestLease& lease) {
  return [&pane, &lease] {
    if (lease.Complete(pane.document, pane.selected, pane.enabled)) ++pane.writes;
  };
}
}
int main() {
  using namespace cio;
  Check(ValidPasswordProvider(0) && ValidPasswordProvider(1) && ValidPasswordProvider(2), "valid provider enum");
  Check(!ValidPasswordProvider(-1) && !ValidPasswordProvider(3), "invalid provider cannot enable filling");
  Check(!ChromiumPasswordsAllowed(0) && !ChromiumPasswordsAllowed(2) && ChromiumPasswordsAllowed(1), "vault coordination");
  Check(ProviderAfterSavingChange(0, false) == 0, "Apple false privacy override keeps Apple selected");
  Check(ProviderAfterSavingChange(1, false) == 2, "engine saving off updates provider and filling");
  Check(ProviderAfterSavingChange(2, false) == 2, "off remains off");
  Check(ProviderAfterSavingChange(0, true) == 1 && ProviderAfterSavingChange(2, true) == 1, "upstream enable reflects engine choice");
  Check(!AppleMayControlPreference("autofill.credit_card_enabled"), "Apple cannot alter cards");
  Check(!AppleMayControlPreference("autofill.profile_enabled"), "Apple cannot alter addresses");
  Check(!AppleMayControlPreference("autofill.enabled"), "deprecated autofill override cannot alter cards or addresses");
  Check(AppleMayControlPreference("credentials_enable_service"), "Apple may control native password saving");

  Check(NextPasswordSuggestionIndex(-1, 3, 1) == 0, "Down starts at first account");
  Check(NextPasswordSuggestionIndex(-1, 3, -1) == 2, "Up starts at last account");
  Check(NextPasswordSuggestionIndex(2, 3, 1) == 0 && NextPasswordSuggestionIndex(0, 3, -1) == 2, "keyboard account selection wraps");
  Check(NextPasswordSuggestionIndex(-1, 0, 1) == -1, "empty list has no keyboard target");
  PasswordRouteLease route;
  Check(!route.Respond(true), "unsolicited credential reply cannot acquire a target");
  Check(route.Request(true) && route.Request(true), "same-document Apple requests may share routing envelope");
  Check(route.Respond(true) && !route.idle(), "first opaque reply retains the pending target");
  Check(route.Respond(true) && route.idle(), "last reply releases target for normal next-page use");
  Check(!route.Respond(true), "duplicate opaque credential response is rejected");
  PasswordRouteLease stale_route;
  Check(stale_route.Request(true), "capture native credential request");
  stale_route.Cancel();
  Check(!stale_route.Request(true), "new document cannot overwrite an outstanding revoked Apple target");
  Check(!stale_route.Respond(true), "out-of-order old ciphertext never binds to new document");
  PasswordRouteLease document_route;
  Check(document_route.Request(true) && !document_route.Respond(false), "native reply after iframe document navigation is denied");

  FakePane left, right;
  PasswordRequestLease left_request(1), right_request(1);
  auto fill_left = Request(left, left_request);
  auto fill_right = Request(right, right_request);
  fill_right(); fill_right();
  Check(right.writes == 1 && left.writes == 0, "split requests never use global current pane and complete once");
  left.selected = false; fill_left();
  Check(left.writes == 0, "asynchronous auth on inactive pane is denied");
  left_request.Cancel(); left.selected = true; fill_left();
  Check(left.writes == 0, "switch away and back cannot revive canceled request");

  FakePane navigation;
  PasswordRequestLease nav_request(1);
  auto stale_fill = Request(navigation, nav_request);
  navigation.document = 2; stale_fill();
  Check(navigation.writes == 0, "cross-document navigation rejects old callback even with reused frame");
  FakePane iframe;
  PasswordRequestLease frame_request(3);
  iframe.document = 4;
  auto stale_frame_fill = Request(iframe, frame_request); stale_frame_fill();
  Check(iframe.writes == 0, "iframe document identity rejects a navigated frame");
  FakePane spa;
  PasswordRequestLease spa_request(1);
  auto spa_fill = Request(spa, spa_request);
  spa_request.Cancel(); spa_fill();
  Check(spa.writes == 0, "same-document SPA start revokes old surface");
  FakePane changed;
  PasswordRequestLease changed_request(1);
  auto late_auth = Request(changed, changed_request);
  changed.enabled = false; late_auth();
  Check(changed.writes == 0, "provider change during authorization rejects completion");
  FakePane closed;
  PasswordRequestLease closed_request(1);
  auto after_close = Request(closed, closed_request);
  closed_request.Cancel(); after_close();
  Check(closed.writes == 0, "page close prevents delayed write");
  FakePane reentrant;
  PasswordRequestLease reentrant_request(1);
  auto reentrant_fill = Request(reentrant, reentrant_request);
  if (reentrant_request.Complete(1, true, true)) { ++reentrant.writes; reentrant_fill(); }
  Check(reentrant.writes == 1, "lease is consumed before reentrant callback");

  AppleConnectionGate gate;
  const auto first = gate.Begin();
  Check(first != 0 && gate.state() == AppleTransport::kConnecting, "Apple first attempt admitted");
  Check(!gate.Begin(), "duplicate native connect during first launch is denied");
  gate.Connected(first);
  Check(gate.state() == AppleTransport::kConnected, "connected represents pipes only");
  gate.Fail(first, AppleTransport::kDisconnected);
  Check(!gate.Begin(), "native-host exit does not cause automatic reload loop");
  gate.Retry(); const auto second = gate.Begin();
  Check(second > first, "manual retry starts new connection epoch");
  gate.Fail(first, AppleTransport::kForbidden);
  Check(gate.state() == AppleTransport::kConnecting, "old connection close cannot corrupt retry state");
  gate.Connected(second);
  Check(gate.state() == AppleTransport::kConnected, "new connection survives old async results");
  for (auto error : {AppleTransport::kNotFound, AppleTransport::kForbidden,
                     AppleTransport::kFailedToStart, AppleTransport::kDisconnected}) {
    gate.Fail(second, error);
    Check(gate.state() == error && !gate.Begin(), "connection failures are terminal until user retry");
  }
  gate.Retry();
  std::atomic<int> winners{0};
  std::vector<std::thread> workers;
  for (int i = 0; i < 32; ++i) workers.emplace_back([&] { if (gate.Begin()) ++winners; });
  for (auto& worker : workers) worker.join();
  Check(winners == 1, "concurrent service-worker connection attempts have one winner");
  std::cout << "PASS: " << checks << " password ownership, lifecycle, preference and transport checks; no credential data accessed\n";
}
