#!/usr/bin/env python3
"""Compile the actual FedCM widget factory against native-host fixtures.

No app launch or account/network access. This checks the window-parenting crash
and both dialog variants; it is not an end-to-end identity-provider test.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/ChromiumBuild/src'
WORK = ROOT / 'build/verification/fedcm-dialog'


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
    source = (SOURCE / 'chrome/browser/ui/views/webid/fedcm_account_selection_view_desktop.cc').read_text()
    start = source.index('std::unique_ptr<views::Widget> FedCmAccountSelectionView::CreateDialogWidget()')
    end = source.index('\nstd::unique_ptr<views::View>', start)
    (WORK / 'FedCmDialogFactory.inc').write_text(source[start:end])
    native = (ROOT / 'Engine/CioChromium/Native/CioFedCmDialogs.mm').read_text()
    (WORK / 'PrepareFedCmDialog.inc').write_text(
        function_body(native, 'void PrepareFedCmDialog('))
    (WORK / 'FedCmDialogRouting.inc').write_text(''.join(
        function_body(source, signature) for signature in (
            'void FedCmAccountSelectionView::ShowDialog(',
            'void FedCmAccountSelectionView::UpdateDialogPosition()',
            'void FedCmAccountSelectionView::UpdateDialogVisibility(',
            'bool FedCmAccountSelectionView::IsDialogManaged(',
            'void FedCmAccountSelectionView::HideDialogWidget()')))
    executable = WORK / 'FedCmDialogTest'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(WORK),
                    str(ROOT / 'Engine/CioChromium/Tests/FedCmDialogTest.cc'),
                    '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
    (WORK / 'factory.log').write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(f'FAIL: FedCM widget factory exited {result.returncode}')


if __name__ == '__main__':
    main()
