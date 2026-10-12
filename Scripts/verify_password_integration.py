#!/usr/bin/env python3
"""Run secret-free tests against Cio's actual password admission/policy code.

This is a command-line test executable, not Cio and not a browser/runtime launch.
It neither initializes a Profile nor accesses any password/Keychain data.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/verification/passwords'

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

if __name__ == '__main__':
    main()
