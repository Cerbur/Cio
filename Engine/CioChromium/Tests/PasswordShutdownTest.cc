// The verifier extracts the generated Chromium method bodies into the include
// below. Only their surrounding store/backend and write payload are synthetic.
// This executable links Chromium base; it never creates a Profile or an app.
#include <atomic>
#include <cstdio>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/at_exit.h"
#include "base/check.h"
#include "base/check_op.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted.h"
#include "base/run_loop.h"
#include "base/sequence_checker.h"
#include "base/synchronization/waitable_event.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/single_thread_task_executor.h"
#include "base/task/thread_pool.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "base/threading/thread_restrictions.h"
#include "base/trace_event/trace_event.h"

namespace password_manager {

class PasswordStoreBuiltInBackend {
 public:
  explicit PasswordStoreBuiltInBackend(
      scoped_refptr<base::SequencedTaskRunner> runner)
      : background_task_runner_(std::move(runner)) {}
  void FlushForShutdown(base::OnceCallback<void(bool)> completion);

 private:
  scoped_refptr<base::SequencedTaskRunner> background_task_runner_;
  SEQUENCE_CHECKER(sequence_checker_);
};

class PasswordStore : public base::RefCountedThreadSafe<PasswordStore> {
 public:
  PasswordStore(std::unique_ptr<PasswordStoreBuiltInBackend> backend,
                bool initializing)
      : backend_(std::move(backend)),
        main_task_runner_(base::SequencedTaskRunner::GetCurrentDefault()) {
    if (!initializing) post_init_callback_.Reset();
  }
  void FlushForShutdown(base::OnceCallback<void(bool)> completion);
  void OnInitCompleted(bool success);
  void OnUnblocklistCompleted(base::OnceClosure completion);

  // Assemble deferred work around the actual Flush/OnInitCompleted methods;
  // no imitation implementation of either tested method lives in this fixture.
  void DeferWrite(base::OnceClosure write) {
    CHECK(post_init_callback_);
    post_init_callback_ = std::move(post_init_callback_).Then(std::move(write));
  }
  bool initializing() const { return !!post_init_callback_; }
  // Synthetic admission only: completion and drain dispatch use extracted
  // production methods. No matching credentials or database reads are needed.
  void BeginCompoundWrite() { ++pending_unblocklists_; }
  unsigned pending_compounds() const { return pending_unblocklists_; }
  size_t deferred_flushes() const { return pending_shutdown_flushes_.size(); }

 private:
  friend class base::RefCountedThreadSafe<PasswordStore>;
  ~PasswordStore() = default;
  std::unique_ptr<PasswordStoreBuiltInBackend> backend_;
  scoped_refptr<base::SequencedTaskRunner> main_task_runner_;
  base::OnceClosure post_init_callback_ = base::DoNothing();
  unsigned pending_unblocklists_ = 0;
  std::vector<base::OnceCallback<void(bool)>> pending_shutdown_flushes_;
};

#include "PasswordShutdownMethods.inc"

}  // namespace password_manager

namespace {

struct WriteState {
  base::WaitableEvent entered;
  base::WaitableEvent release;
  std::atomic<bool> released{false};
  std::atomic<int> writes_completed{0};
  std::vector<std::string> submitted;  // Main sequence only.
};

base::OnceClosure WriteTask(WriteState* state, base::FilePath path,
                            std::string bytes, bool hold) {
  return base::BindOnce(
      [](WriteState* state, base::FilePath path, std::string bytes, bool hold) {
        if (hold) {
          base::ScopedAllowBaseSyncPrimitivesForTesting allow_held_write;
          state->entered.Signal();
          state->release.Wait();
        }
        // The payload is just test markers, never credentials or a Login DB.
        base::File file(path, base::File::FLAG_CREATE_ALWAYS |
                                 base::File::FLAG_WRITE);
        CHECK(file.IsValid());
        CHECK(file.WriteAtCurrentPosAndCheck(base::as_byte_span(bytes)));
        CHECK(file.Flush());
        file.Close();
        ++state->writes_completed;
      }, state, std::move(path), std::move(bytes), hold);
}

base::OnceClosure SubmitWrite(scoped_refptr<base::SequencedTaskRunner> runner,
                              WriteState* state, base::FilePath path,
                              std::string bytes, bool hold) {
  return base::BindOnce(
      [](scoped_refptr<base::SequencedTaskRunner> runner, WriteState* state,
         base::FilePath path, std::string bytes, bool hold) {
        state->submitted.push_back(bytes);
        CHECK(runner->PostTask(
            FROM_HERE, WriteTask(state, std::move(path), std::move(bytes), hold)));
      }, std::move(runner), state, std::move(path), std::move(bytes), hold);
}

void HeldWriteDrain(bool initializing) {
  base::ScopedTempDir directory;
  CHECK(directory.CreateUniqueTempDir());
  const auto path = directory.GetPath().AppendASCII("synthetic-write-marker");
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE});
  auto store = base::MakeRefCounted<password_manager::PasswordStore>(
      std::make_unique<password_manager::PasswordStoreBuiltInBackend>(runner),
      initializing);
  WriteState state;
  auto first = SubmitWrite(runner, &state, path, "save-marker", true);
  auto second = SubmitWrite(runner, &state, path, "update-marker", false);
  if (initializing) {
    store->DeferWrite(std::move(first));
    store->DeferWrite(std::move(second));
  } else {
    std::move(first).Run();
    std::move(second).Run();
  }

  int callbacks = 0;
  base::RunLoop drained;
  store->FlushForShutdown(base::BindOnce(
      [](scoped_refptr<base::SequencedTaskRunner> caller, WriteState* state,
         const base::FilePath& path, int* callbacks,
         base::OnceClosure quit, bool success) {
        CHECK(caller->RunsTasksInCurrentSequence());
        CHECK(success);
        CHECK(state->released.load()) << "flush completed before write release";
        CHECK_EQ(state->writes_completed.load(), 2);
        std::string bytes;
        CHECK(base::ReadFileToString(path, &bytes));
        CHECK_EQ(bytes, "update-marker");
        CHECK_EQ(++*callbacks, 1);
        std::move(quit).Run();
      }, base::SequencedTaskRunner::GetCurrentDefault(), &state, path,
      &callbacks, drained.QuitClosure()));

  // Pump only the caller sequence. A global ThreadPool drain here would hang
  // behind the intentionally held task and could mask the ordering regression.
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 0);
  if (initializing) {
    CHECK(state.submitted.empty());
    CHECK(store->initializing());
    store->OnInitCompleted(true);  // Actual extracted initialization completion.
    CHECK(!store->initializing());
  }
  state.entered.Wait();  // Handshake, never a sleep or timing assumption.
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 0);
  CHECK_EQ(state.writes_completed.load(), 0);
  CHECK(state.submitted == (std::vector<std::string>{"save-marker", "update-marker"}));
  CHECK(!base::PathExists(path));
  state.released = true;
  state.release.Signal();
  drained.Run();
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 1);

  // A second call gets its own asynchronous reply, including with an idle DB.
  base::RunLoop repeated;
  int repeated_callbacks = 0;
  store->FlushForShutdown(base::BindOnce(
      [](int* calls, base::OnceClosure quit, bool success) {
        CHECK(success);
        CHECK_EQ(++*calls, 1);
        std::move(quit).Run();
      }, &repeated_callbacks, repeated.QuitClosure()));
  CHECK_EQ(repeated_callbacks, 0);
  repeated.Run();
  CHECK_EQ(repeated_callbacks, 1);
  std::printf("PASS: %s; held write blocks reply, FIFO bytes persist before reply, repeated flush\n",
              initializing ? "initialization-deferred drain" : "initialized drain");
}

void BackendUnavailable() {
  for (bool initializing : {false, true}) {
    auto store = base::MakeRefCounted<password_manager::PasswordStore>(
        nullptr, initializing);
    int calls = 0;
    store->FlushForShutdown(base::BindOnce([](int* calls, bool success) {
      CHECK(!success);
      CHECK_EQ(++*calls, 1);
    }, &calls));
    base::RunLoop().RunUntilIdle();
    CHECK_EQ(calls, 1);
  }
  std::puts("PASS: absent backend reports false once, including pending initialization");
}

void CompoundWriteDrain() {
  base::ScopedTempDir directory;
  CHECK(directory.CreateUniqueTempDir());
  const auto path = directory.GetPath().AppendASCII("compound-write-marker");
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE});
  auto store = base::MakeRefCounted<password_manager::PasswordStore>(
      std::make_unique<password_manager::PasswordStoreBuiltInBackend>(runner),
      false);
  WriteState state;
  store->BeginCompoundWrite();
  store->BeginCompoundWrite();
  int callbacks = 0;
  base::RunLoop drained;
  for (int i = 0; i < 2; ++i) {
    store->FlushForShutdown(base::BindOnce(
        [](scoped_refptr<base::SequencedTaskRunner> caller, WriteState* state,
           base::FilePath path, int* calls, base::RepeatingClosure quit,
           bool success) {
          CHECK(caller->RunsTasksInCurrentSequence());
          CHECK(success);
          CHECK(state->released.load()) << "flush completed before compound write release";
          CHECK_EQ(state->writes_completed.load(), 2);
          std::string bytes;
          CHECK(base::ReadFileToString(path, &bytes));
          CHECK_EQ(bytes, "compound-final-marker");
          CHECK_LE(++*calls, 2);
          if (*calls == 2) quit.Run();
        }, base::SequencedTaskRunner::GetCurrentDefault(), &state, path,
        &callbacks, drained.QuitClosure()));
  }
  CHECK_EQ(store->deferred_flushes(), 2u)
      << "flush was not deferred behind outstanding compound operations";
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 0);

  // Completing one of multiple operations must not start either barrier.
  store->OnUnblocklistCompleted(base::OnceClosure());
  CHECK_EQ(store->pending_compounds(), 1u);
  CHECK_EQ(store->deferred_flushes(), 2u);
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 0);

  // The original completion can admit another compound operation and post
  // writes. The actual completion method must run it before releasing flushes.
  store->OnUnblocklistCompleted(base::BindOnce(
      [](scoped_refptr<password_manager::PasswordStore> store,
         base::OnceClosure submit) {
        CHECK_EQ(store->pending_compounds(), 0u);
        CHECK_EQ(store->deferred_flushes(), 2u)
            << "flush started before original compound completion";
        store->BeginCompoundWrite();
        std::move(submit).Run();
      }, store, SubmitWrite(runner, &state, path, "compound-first-marker", true)));
  CHECK_EQ(store->pending_compounds(), 1u);
  CHECK_EQ(store->deferred_flushes(), 2u);
  state.entered.Wait();
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 0);

  // The new operation's callback posts the final write before both backend
  // barriers. The worker remains blocked until the explicit release below.
  store->OnUnblocklistCompleted(
      SubmitWrite(runner, &state, path, "compound-final-marker", false));
  CHECK_EQ(store->pending_compounds(), 0u);
  CHECK_EQ(store->deferred_flushes(), 0u);
  CHECK(state.submitted ==
        (std::vector<std::string>{"compound-first-marker", "compound-final-marker"}));
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 0);
  CHECK_EQ(state.writes_completed.load(), 0);
  CHECK(!base::PathExists(path));
  state.released = true;
  state.release.Signal();
  drained.Run();
  base::RunLoop().RunUntilIdle();
  CHECK_EQ(callbacks, 2);
  std::puts("PASS: compound drain; multiple operations/flushes, reentrant completion, held callback writes persist before replies");
}

}  // namespace

int main(int argc, char** argv) {
  base::AtExitManager at_exit;
  base::SingleThreadTaskExecutor executor;
  base::ScopedAllowBlockingForTesting allow_file_io;
  base::ScopedAllowBaseSyncPrimitivesForTesting allow_handshakes;
  base::ThreadPoolInstance::CreateAndStartWithDefaultParams("PasswordShutdownTest");
  const std::string_view mode = argc == 2 ? argv[1] : "--all";
  CHECK(mode == "--all" || mode == "--initialized" || mode == "--deferred" ||
        mode == "--unavailable" || mode == "--compound");
  if (mode == "--all" || mode == "--initialized") HeldWriteDrain(false);
  if (mode == "--all" || mode == "--deferred") HeldWriteDrain(true);
  if (mode == "--all" || mode == "--unavailable") BackendUnavailable();
  if (mode == "--all" || mode == "--compound") CompoundWriteDrain();
  base::ThreadPoolInstance::Get()->Shutdown();
  base::ThreadPoolInstance::Get()->JoinForTesting();
  std::puts("PASS: extracted password shutdown methods; no app, Profile, credentials or Keychain");
}
