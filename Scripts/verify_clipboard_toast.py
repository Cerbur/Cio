#!/usr/bin/env python3
"""Replay image-copy toast admission with the pinned Chromium function bodies.

No app launch or system clipboard access. The fixture supplies an AppKit host
without a Chrome Views anchor, reproducing the reported CHECK_IS_TEST abort.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/ChromiumBuild/src'
WORK = ROOT / 'build/verification/clipboard-toast'


def function_body(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end] + '\n'


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    from build_native_chromium import prepare
    prepare()
    toast = (SOURCE / 'chrome/browser/ui/toasts/toast_controller.cc').read_text()
    bodies = ''.join(function_body(toast, signature) for signature in (
        'bool ToastController::CanShowToast(',
        'bool ToastController::MaybeShowToast('))
    # Only the actual anchor admission block is needed to reproduce the abort;
    # rendering a Views bubble is outside this isolated test's scope.
    create = function_body(toast, 'void ToastController::CreateToast(')
    bodies += create[:create.index('  const std::u16string body_string =')] + '}\n'
    menu = (SOURCE / 'chrome/browser/renderer_context_menu/render_view_context_menu.cc').read_text()
    bodies += function_body(menu, 'void RenderViewContextMenu::ExecCopyImageAt()')
    (WORK / 'ClipboardToast.inc').write_text(bodies)
    executable = WORK / 'ClipboardToastTest'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-I' + str(WORK),
                    str(ROOT / 'Engine/CioChromium/Tests/ClipboardToastTest.cc'),
                    '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
    (WORK / 'toast.log').write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(f'FAIL: image-copy toast exited {result.returncode}')


if __name__ == '__main__':
    main()
