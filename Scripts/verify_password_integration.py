#!/usr/bin/env python3
"""Run secret-free tests against Cio's actual password admission/policy code.

This is a command-line test executable, not Cio and not a browser/runtime launch.
It neither initializes a Profile nor accesses any password/Keychain data.
"""
from pathlib import Path
import resource
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/verification/passwords'

def method(text, signature):
    start = text.index(signature)
    body = text.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

def check_prompt_controllers():
    source = ROOT / 'build/ChromiumBuild/src/chrome/browser/ui/passwords/bubble_controllers'
    methods = []
    for filename, signatures in (
        ('save_update_bubble_controller.cc', ['void SaveUpdateBubbleController::OnNotNowClicked()']),
        ('common_saved_account_manager_bubble_controller.cc', [
            'void CommonSavedAccountManagerBubbleController::OnNoThanksClicked()',
            'void CommonSavedAccountManagerBubbleController::OnCredentialEdited(']),
        ('add_username_bubble_controller.cc', ['void AddUsernameBubbleController::OnSaveClicked()']),
    ):
        text = (source / filename).read_text()
        methods.extend(method(text, signature) for signature in signatures)
    (WORK / 'PasswordPromptMethods.inc').write_text('\n\n'.join(methods))
    executable = WORK / 'PasswordPromptControllerTest'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(ROOT), '-I' + str(WORK),
                    str(ROOT / 'Engine/CioChromium/Tests/PasswordPromptControllerTest.cc'),
                    '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20, check=True)
    def disable_core_dump():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    regression = subprocess.run([str(executable), '--old-update-dismissal'],
                                capture_output=True, timeout=20, preexec_fn=disable_core_dump)
    if regression.returncode != -6:
        raise RuntimeError('Pinned update-dismissal CHECK was not exercised')
    output = result.stdout + 'PASS: previous update-dismissal path reproduces upstream SIGABRT\n'
    (WORK / 'prompt-controller-tests.log').write_text(output)
    print(output, end='')

def main():
    WORK.mkdir(parents=True, exist_ok=True)
    executable = WORK / 'PasswordPolicyTest'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-pthread', '-I' + str(ROOT),
                    str(ROOT / 'Engine/CioChromium/Tests/PasswordPolicyTest.cc'),
                    '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20, check=True)
    (WORK / 'policy-tests.log').write_text(result.stdout)
    print(result.stdout, end='')
    check_prompt_controllers()

if __name__ == '__main__':
    main()
