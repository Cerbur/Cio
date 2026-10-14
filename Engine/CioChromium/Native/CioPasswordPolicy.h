#pragma once

#include <atomic>
#include <cstdint>
#include <string_view>
#include <utility>

namespace cio {
inline constexpr char kPasswordProviderPref[] = "cio.password_provider";
inline constexpr char kApplePasswordExtension[] = "pejdijmoenmkgeppbflobdenhhabjlaj";
inline constexpr char kApplePasswordHost[] = "com.apple.passwordmanager";
enum class PasswordProvider { kApple = 0, kChromium = 1, kOff = 2 };
inline int InitialPasswordProvider(bool apple_installed, bool saving_enabled) {
  // Used only when no explicit Cio provider is stored. An installed Apple
  // extension and an existing save-disabled preference remain authoritative.
  if (apple_installed) return static_cast<int>(PasswordProvider::kApple);
  return static_cast<int>(saving_enabled ? PasswordProvider::kChromium : PasswordProvider::kOff);
}
template <typename Controller>
void DeclinePasswordPrompt(Controller& controller, bool update_prompt) {
  // Chromium has different delegates and CHECKs for save and update dismissal.
  if (update_prompt) controller.OnNoThanksClicked();
  else controller.OnNotNowClicked();
}
inline bool ValidPasswordProvider(int value) { return value >= 0 && value <= 2; }
inline bool ChromiumPasswordsAllowed(int provider) {
  return provider == static_cast<int>(PasswordProvider::kChromium);
}
inline int ProviderAfterSavingChange(int provider, bool saving) {
  // Apple's false privacy override is not permission to change vaults.
  return saving ? 1 : ChromiumPasswordsAllowed(provider) ? 2 : provider;
}
inline bool AppleMayControlPreference(std::string_view preference) {
  return preference != "autofill.credit_card_enabled" &&
         preference != "autofill.profile_enabled" &&
         preference != "autofill.enabled";
}
inline int NextPasswordSuggestionIndex(int current, int count, int direction) {
  if (count <= 0) return -1;
  if (current < 0) return direction < 0 ? count - 1 : 0;
  return (current + direction + count) % count;
}

// Multiple opaque replies may arrive in any order for the same Apple routing
// key. They may share one document, but a revoked target can never be rebound
// until that connection is discarded. No password/ciphertext is retained.
class PasswordRouteLease {
 public:
  bool Request(bool document_valid) {
    if (!document_valid || revoked_) return false;
    ++pending_;
    return true;
  }
  bool Respond(bool document_valid) {
    if (!document_valid || revoked_ || pending_ == 0) return false;
    --pending_;
    return true;
  }
  void Cancel() { revoked_ = true; }
  bool idle() const { return pending_ == 0; }
 private:
  unsigned pending_ = 0;
  bool revoked_ = false;
};

// Transport health is deliberately separate from Apple's encrypted pairing
// protocol. Connected means pipes opened, never that the vault is unlocked.
enum class AppleTransport { kUntried, kConnecting, kConnected, kNotFound,
                            kForbidden, kFailedToStart, kDisconnected, kStaleTarget };
class AppleConnectionGate {
 public:
  uint64_t Begin() {
    auto expected = state_.load();
    if (Status(expected) != AppleTransport::kUntried) return 0;
    return state_.compare_exchange_strong(expected, Word(expected >> 8, AppleTransport::kConnecting))
        ? expected >> 8 : 0;
  }
  void Connected(uint64_t epoch) {
    auto expected = Word(epoch, AppleTransport::kConnecting);
    state_.compare_exchange_strong(expected, Word(epoch, AppleTransport::kConnected));
  }
  void Fail(uint64_t epoch, AppleTransport reason) {
    auto expected = state_.load();
    while (expected >> 8 == epoch &&
           !state_.compare_exchange_weak(expected, Word(epoch, reason))) {}
  }
  void Retry() {
    auto expected = state_.load();
    while (!state_.compare_exchange_weak(expected, Word((expected >> 8) + 1, AppleTransport::kUntried))) {}
  }
  AppleTransport state() const { return Status(state_.load()); }
 private:
  static uint64_t Word(uint64_t epoch, AppleTransport status) {
    return epoch << 8 | static_cast<uint64_t>(status);
  }
  static AppleTransport Status(uint64_t word) { return static_cast<AppleTransport>(word & 255); }
  std::atomic<uint64_t> state_{Word(1, AppleTransport::kUntried)};
};

// Shared, secret-free admission rule for callbacks. A UI request is invalidated
// before invoking a callback, including callbacks which synchronously destroy
// its owner. Navigation, pane selection and preference changes revoke it.
class PasswordRequestLease {
 public:
  explicit PasswordRequestLease(uint64_t document) : document_(document) {}
  bool CanAct(uint64_t document, bool owns_keyboard, bool enabled) const {
    return active_ && document == document_ && owns_keyboard && enabled;
  }
  bool Complete(uint64_t document, bool owns_keyboard, bool enabled) {
    if (!CanAct(document, owns_keyboard, enabled)) return false;
    return std::exchange(active_, false);
  }
  void Cancel() { active_ = false; }
 private:
  const uint64_t document_;
  bool active_ = true;
};
}  // namespace cio
