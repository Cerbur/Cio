#!/usr/bin/env bash
# Atomically install a full, version-matched CEF binary distribution. This
# replaces framework, headers AND wrapper sources; never mix CEF versions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 1 ]]; then
  echo 'usage: Scripts/install_cef_runtime.sh /path/to/cef_distribution' >&2
  exit 1
fi
python3 - "$REPO_ROOT" "$1" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root, source = (Path(arg).resolve() for arg in sys.argv[1:])
target = root / 'ThirdParty/CEF'
if source == target or target in source.parents or source in target.parents:
    sys.exit('error: source must be a separate CEF distribution')
required = ('include/cef_app.h', 'include/cef_version.h', 'libcef_dll',
            'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework')
for item in required:
    if not (source / item).exists():
        sys.exit(f'error: incomplete distribution: missing {item}')

def version(directory):
    header = (directory / 'include/cef_version.h').read_text()
    match = re.search(r'^#define CEF_VERSION "([^"]+)"', header, re.M)
    if not match:
        sys.exit('error: cannot identify CEF version')
    return match.group(1)

if version(source) != version(target):
    sys.exit('error: CEF version mismatch; upgrade headers, runtime and recipe together')
subprocess.run(['xcrun', 'lipo', '-verify_arch', 'arm64', str(source / required[-1])],
               check=True)

# Stage on the same volume so the live directory is swapped by rename. Keep
# the previous distribution for recovery rather than deleting the only copy.
stage = Path(tempfile.mkdtemp(prefix='.cef-install-', dir=target.parent))
backup = stage / 'previous'
try:
    shutil.copytree(source, stage / 'new', symlinks=True)
    target.rename(backup)
    try:
        (stage / 'new').rename(target)
    except BaseException:
        backup.rename(target)
        raise
except BaseException:
    if not backup.exists():
        shutil.rmtree(stage)
    raise

# Old object timestamps cannot establish ABI compatibility after a swap.
library = root / 'ThirdParty/libcef_dll_wrapper.a'
library.unlink(missing_ok=True)
shutil.rmtree(root / 'ThirdParty/wrapper-build', ignore_errors=True)
print(f'Installed CEF {version(target)}. Previous runtime: {backup}')
print('Rebuild from the repository root with CONFIGURATION=Debug Scripts/build.sh')
PY
