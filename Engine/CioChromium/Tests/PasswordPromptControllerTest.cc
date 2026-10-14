// Exercise Cio's dismissal dispatch against the exact pinned Chromium methods.
// Only the surrounding Profile-free controller/delegate fixture is synthetic.
#include "Engine/CioChromium/Native/CioPasswordPolicy.h"
#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>

#define CHECK(condition) do { if (!(condition)) std::abort(); } while (false)
#define CHECK_EQ(left, right) CHECK((left) == (right))
namespace password_manager {
namespace ui {
enum State { PENDING_PASSWORD_STATE, PENDING_PASSWORD_UPDATE_STATE,
             GENERATED_PASSWORD_CONFIRMATION_STATE };
}
namespace metrics_util {
enum UIDismissalReason { CLICKED_NOT_NOW, CLICKED_CANCEL, CLICKED_ACCEPT };
}
}
namespace metrics_util = password_manager::metrics_util;
struct PasswordForm { std::u16string username_value, password_value; };
struct Delegate {
  int not_now = 0, declined_update = 0, added_username = 0;
  std::u16string account;
  PasswordForm original;
  void OnNotNowClicked() { ++not_now; }
  void OnNopeUpdateClicked() { ++declined_update; }
  void OnAddUsernameSaveClicked(const std::u16string& username, const PasswordForm& form) {
    ++added_username; account = username; original = form;
  }
};
class CommonSavedAccountManagerBubbleController {
 public:
  CommonSavedAccountManagerBubbleController(password_manager::ui::State state, Delegate* delegate)
      : state_(state), delegate_(delegate) {}
  void OnNoThanksClicked();
  void OnCredentialEdited(std::u16string username, std::u16string password);
  auto GetState() const { return state_; }
  void SetDismissalReason(metrics_util::UIDismissalReason reason) { dismissal_reason_ = reason; }
  const PasswordForm& pending_password() const { return pending_password_; }
 protected:
  password_manager::ui::State state_;
  Delegate* delegate_;
  metrics_util::UIDismissalReason dismissal_reason_ = metrics_util::CLICKED_CANCEL;
  PasswordForm pending_password_;
};
class SaveUpdateBubbleController : public CommonSavedAccountManagerBubbleController {
 public:
  using CommonSavedAccountManagerBubbleController::CommonSavedAccountManagerBubbleController;
  void OnNotNowClicked();
};
class AddUsernameBubbleController : public CommonSavedAccountManagerBubbleController {
 public:
  AddUsernameBubbleController(Delegate* delegate)
      : CommonSavedAccountManagerBubbleController(password_manager::ui::GENERATED_PASSWORD_CONFIRMATION_STATE,
                                                   delegate) {}
  void OnSaveClicked();
 private:
  const PasswordForm ininial_pending_password_{u"", u"synthetic-generated-password"};
};
#include "PasswordPromptMethods.inc"

void Expect(bool condition) { CHECK(condition); }
int main(int argc, char** argv) {
  Delegate delegate;
  SaveUpdateBubbleController save(password_manager::ui::PENDING_PASSWORD_STATE, &delegate);
  SaveUpdateBubbleController update(password_manager::ui::PENDING_PASSWORD_UPDATE_STATE, &delegate);
  // The verifier runs this separately: the old Cio update dismissal must hit
  // the upstream CHECK, proving the fixture retains the actual failing guard.
  if (argc == 2 && std::string(argv[1]) == "--old-update-dismissal") {
    update.OnNotNowClicked();
    return 0;
  }
  cio::DeclinePasswordPrompt(save, false);
  Expect(delegate.not_now == 1 && delegate.declined_update == 0);
  cio::DeclinePasswordPrompt(update, true);
  Expect(delegate.not_now == 1 && delegate.declined_update == 1);
  AddUsernameBubbleController generated(&delegate);
  generated.OnCredentialEdited(u"fixture-account", generated.pending_password().password_value);
  generated.OnSaveClicked();
  Expect(delegate.added_username == 1 && delegate.account == u"fixture-account");
  Expect(delegate.original.username_value.empty() &&
         delegate.original.password_value == u"synthetic-generated-password");
  generated.OnNoThanksClicked();
  Expect(delegate.declined_update == 2);
  std::cout << "PASS: pinned save/update dismissal and generated-password account association\n";
}
