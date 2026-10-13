#!/usr/bin/env python3
"""Exercise the actual sad-tab lookup without launching Cio or a renderer.

Compiles the pinned function with window fixtures. This catches the native
host/Views mismatch, but does not claim end-to-end renderer recovery coverage.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/ChromiumBuild/src'
WORK = ROOT / 'build/verification/renderer-crash'


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    # prepare() writes exactly the same pinned overlay consumed by build.sh.
    from build_native_chromium import prepare
    prepare()
    source = (SOURCE / 'chrome/browser/ui/sad_tab_controller.cc').read_text()
    start = source.index('ContentsWebView* FindContentsWebView(')
    end = source.index('\n}  // namespace', start)
    (WORK / 'SadTabLookup.inc').write_text(source[start:end])
    executable = WORK / 'SadTabLookupTest'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(WORK),
                    str(ROOT / 'Engine/CioChromium/Tests/SadTabLookupTest.cc'),
                    '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
    (WORK / 'lookup.log').write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(f'FAIL: sad-tab lookup exited {result.returncode}')


if __name__ == '__main__':
    main()
