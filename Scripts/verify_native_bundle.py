#!/usr/bin/env python3
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/DerivedData/Build/Products' / os.environ.get('CONFIGURATION', 'Debug') / 'Cio.app'
FW = APP / 'Contents/Frameworks'

def output(*args): return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def inspect(path):
    with tempfile.TemporaryDirectory(prefix='cio-verify-') as directory:
        image = Path(directory) / 'image'
        shutil.copy2(path, image)
        libraries = output('otool', '-L', str(image)).splitlines()[1:]
        load_commands = output('otool', '-l', str(image)).splitlines()
    rpaths = []
    for index, line in enumerate(load_commands):
        if line.strip() == 'cmd LC_RPATH':
            rpaths.append(load_commands[index + 2].strip().split(' (offset')[0].removeprefix('path '))
    assert not any(str(ROOT) in p for p in rpaths), f'Build-directory rpath: {path}'
    roots = [FW, path.parent, path.parent / 'Libraries']
    for rpath in rpaths:
        if rpath.startswith('@loader_path'): roots.append(Path(rpath.replace('@loader_path', str(path.parent))))
        elif rpath.startswith('@executable_path'): roots.append(Path(rpath.replace('@executable_path', str(APP / 'Contents/MacOS'))))
    for line in libraries:
        dependency = line.strip().split(' (compatibility')[0]
        assert 'Chromium Embedded Framework' not in dependency, f'CEF dependency: {path}'
        if dependency.startswith('@rpath/'):
            name = dependency.removeprefix('@rpath/')
            assert any((root / name).exists() for root in roots), f'Missing dependency {dependency}: {path}'
        elif dependency.startswith('@loader_path/'):
            assert (path.parent / dependency.removeprefix('@loader_path/')).exists(), dependency
        else:
            assert dependency.startswith(('/System/', '/usr/lib/')), f'External dependency {dependency}: {path}'
    return path

def main():
    with (APP / 'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
    assert info['CFBundleIdentifier'] == 'com.cerbur.Cio'
    assert info['NSPrincipalClass'] == 'BrowserCrApplication'
    engine = FW / 'Chromium Framework.framework'
    assert engine.exists() and not (FW / 'Chromium Embedded Framework.framework').exists()
    helpers = list((engine / 'Helpers').glob('*.app'))
    assert len(helpers) == 4, 'Expected four standard Chromium helpers'
    notices = APP / 'Contents/Resources/ThirdPartyNotices'
    metadata = json.loads((notices / 'Chromium-BUILD.json').read_text())
    assert metadata['native_backend_built'] and metadata['integrated_in_cio']
    for relative, digest in metadata['overlay'].items():
        assert hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() == digest, f'Stale native overlay: {relative}'
    assert (notices / 'Mori-MIT.txt').read_bytes() == (ROOT / 'ThirdParty/Notices/Mori-MIT.txt').read_bytes()
    for name in ('Chromium-CREDITS.html', 'Chromium-LICENSE.txt', 'THIRD_PARTY_NOTICES.md'):
        assert (notices / name).stat().st_size > 100
    libraries = [FW / name for name in json.loads((notices / 'Chromium-COMPONENTS.json').read_text())]
    binaries = libraries + [FW / 'CioChromium.framework/CioChromium', engine / 'Chromium Framework']
    binaries += [p for p in (APP / 'Contents/MacOS').iterdir() if p.is_file()]
    for helper in helpers:
        with (helper / 'Contents/Info.plist').open('rb') as stream: helper_info = plistlib.load(stream)
        binaries.append(helper / 'Contents/MacOS' / helper_info['CFBundleExecutable'])
    binaries += [p for p in (engine / 'Libraries').rglob('*.dylib') if not p.is_symlink()]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(inspect, binaries))
    output('codesign', '--verify', '--deep', '--strict', str(APP))
    symbols = output('nm', '-gU', str(FW / 'libchrome_dll.dylib'))
    for symbol in ('_CioNativeStart', '_CioNativeIsInitialized', '_OBJC_CLASS_$_BrowserBridge'):
        assert symbol in symbols, f'Missing native export: {symbol}'
    print(f'PASS: native Chromium {metadata["version"]}; {len(libraries)} libraries, four helpers, dyld closure, signatures and licenses')

if __name__ == '__main__': main()
