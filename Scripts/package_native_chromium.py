#!/usr/bin/env python3
"""Bundle the pinned GN component build, with a closed dyld dependency graph."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/ChromiumBuild/src'
ENGINE = SOURCE / 'out/CioDev'
APP = Path(os.environ['BUILT_PRODUCTS_DIR']) / os.environ['WRAPPER_NAME']
CONTENTS = APP / 'Contents'
FRAMEWORKS = CONTENTS / 'Frameworks'

def run(*args):
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode: raise RuntimeError(' '.join(args) + ': ' + result.stderr)

def macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe')

def main():
    metadata = json.loads((ENGINE / 'cio-native-build.json').read_text())
    if not metadata.get('native_backend_built'):
        raise RuntimeError('Native Chromium has not completed its build')
    credits = ENGINE / 'Chromium-CREDITS.html'
    if not credits.exists():
        subprocess.run(['python3', 'tools/licenses/licenses.py', 'credits', '--target-os', 'mac',
                        '--gn-out-dir', 'out/CioDev', '--gn-target', '//chrome:chrome', str(credits)],
                       cwd=SOURCE, check=True)
    FRAMEWORKS.mkdir(parents=True, exist_ok=True)
    for name in ('Cio.debug.dylib', '__preview.dylib'):
        stale = CONTENTS / 'MacOS' / name
        if stale.exists(): stale.unlink()
    # Remove only runtime artifacts from the former build, never profile data.
    old = FRAMEWORKS / 'Chromium Embedded Framework.framework'
    if old.exists(): shutil.rmtree(old)
    for old in FRAMEWORKS.glob('Cio Helper*.app'): shutil.rmtree(old)
    framework = FRAMEWORKS / 'Chromium Framework.framework'
    if framework.exists(): shutil.rmtree(framework)
    run('ditto', str(ENGINE / 'Chromium.app/Contents/Frameworks/Chromium Framework.framework'), str(framework))
    # A component build requires its sibling dylibs in addition to the framework.
    # Keep a manifest so a later upgrade also removes libraries no longer used.
    notices = CONTENTS / 'Resources/ThirdPartyNotices'
    notices.mkdir(parents=True, exist_ok=True)
    manifest = notices / 'Chromium-COMPONENTS.json'
    legacy_manifest = FRAMEWORKS / 'cio-component-libraries.json'
    old_manifest = manifest if manifest.exists() else legacy_manifest
    previous = json.loads(old_manifest.read_text()) if old_manifest.exists() else []
    if legacy_manifest.exists(): legacy_manifest.unlink()
    libraries = sorted(ENGINE.glob('*.dylib'))
    names = [p.name for p in libraries]
    for name in set(previous) - set(names):
        path = FRAMEWORKS / name
        if path.parent == FRAMEWORKS and path.is_file(): path.unlink()
    for path in libraries: shutil.copy2(path, FRAMEWORKS / path.name)
    manifest.write_text(json.dumps(names, indent=2) + '\n')
    # Helpers are nested much deeper than Cio's executable. Give every runtime
    # image its own bundle-relative search path; no build-directory fallback.
    binaries = [p for p in FRAMEWORKS.rglob('*') if macho(p)]
    binaries += [p for p in (CONTENTS / 'MacOS').iterdir() if macho(p)]
    for binary in binaries:
        rpath = '@loader_path/' + os.path.relpath(FRAMEWORKS, binary.parent)
        # Apple's otool treats parentheses in helper names as archive syntax.
        # Inspect/patch a temporary plain filename, then copy it back.
        temporary = tempfile.TemporaryDirectory(prefix='cio-link-')
        image = Path(temporary.name) / 'image'
        shutil.copy2(binary, image)
        output = subprocess.check_output(['otool', '-l', str(image)], text=True)
        old_paths = []
        lines = output.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == 'cmd LC_RPATH':
                old_paths.append(lines[index + 2].strip().split(' (offset')[0].removeprefix('path '))
        for old_path in old_paths:
            run('install_name_tool', '-delete_rpath', old_path, str(image))
        for relative_path in dict.fromkeys((rpath, '@loader_path', '@loader_path/Libraries')):
            run('install_name_tool', '-add_rpath', relative_path, str(image))
        shutil.copy2(image, binary)
        temporary.cleanup()
    notices = CONTENTS / 'Resources/ThirdPartyNotices'
    notices.mkdir(parents=True, exist_ok=True)
    for name in ('CEF-LICENSE.txt', 'CEF-VERSION.txt'):
        path = notices / name
        if path.exists(): path.unlink()
    for origin, name in ((SOURCE / 'LICENSE', 'Chromium-LICENSE.txt'),
                         (credits, 'Chromium-CREDITS.html'),
                         (ROOT / 'ThirdParty/Notices/Mori-MIT.txt', 'Mori-MIT.txt'),
                         (ROOT / 'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md')):
        shutil.copy2(origin, notices / name)
    metadata['integrated_in_cio'] = True
    (notices / 'Chromium-BUILD.json').write_text(json.dumps(metadata, indent=2) + '\n')
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or os.environ.get('CODE_SIGN_IDENTITY')
    if os.environ.get('CODE_SIGNING_ALLOWED', 'YES') != 'NO' and identity:
        signing = ['codesign', '--force', '--sign', identity, '--timestamp=none']
        executable_signing = list(signing)
        if os.environ.get('ENABLE_HARDENED_RUNTIME') == 'YES':
            signing += ['--options', 'runtime']
            executable_signing += ['--options', 'runtime', '--entitlements', str(ROOT / 'Cio/Resources/Cio.entitlements')]
        for binary in binaries:
            # The main executable is sealed by codesign of the app bundle,
            # after all nested frameworks and helper bundles have their seals.
            if FRAMEWORKS not in binary.parents: continue
            args = signing if binary.suffix == '.dylib' or binary.name == 'Chromium Framework' else executable_signing
            run(*args, str(binary))
        helpers = sorted((framework / 'Helpers').glob('*.app'))
        for helper in helpers: run(*executable_signing, str(helper))
        run(*signing, str(framework))
        run(*signing, str(FRAMEWORKS / 'CioChromium.framework'))
        # Xcode's final CodeSign seals the outer app. Refresh existing signatures
        # for incremental builds whose CodeSign task can otherwise be skipped.
        if (CONTENTS / '_CodeSignature').exists():
            entitlements = Path(os.environ['TARGET_TEMP_DIR']) / (os.environ['WRAPPER_NAME'] + '.xcent')
            args = signing + (['--entitlements', str(entitlements)] if entitlements.exists() else [])
            run(*args, str(APP))
    print(f'Packaged native Chromium {metadata["version"]}: {len(libraries)} component libraries, four standard helpers')

if __name__ == '__main__': main()
