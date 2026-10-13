#!/usr/bin/env python3
"""Check that packaging preserves files mapped by an already-running process.

No app launch or profile access. A mapped fixture exposes the same overwritten
vnode problem that makes macOS reject a previously signed code page.
"""
import importlib.util
import mmap
import os
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='cio-runtime-image-') as directory:
        work = Path(directory)
        saved = {key: os.environ.get(key) for key in ('BUILT_PRODUCTS_DIR', 'WRAPPER_NAME')}
        try:
            os.environ.update(BUILT_PRODUCTS_DIR=str(work), WRAPPER_NAME='Cio.app')
            spec = importlib.util.spec_from_file_location(
                'package_native_chromium', ROOT / 'Scripts/package_native_chromium.py')
            package = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(package)
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        old_bytes = b'old signed image' * 4096
        new_bytes = b'new signed image' * 4096
        origin = work / 'new.dylib'
        destination = work / 'loaded.dylib'
        origin.write_bytes(new_bytes)
        origin.chmod(0o755)
        destination.write_bytes(old_bytes)
        with destination.open('rb') as loaded:
            old_inode = os.fstat(loaded.fileno()).st_ino
            with mmap.mmap(loaded.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                package.copy_runtime_image(origin, destination)
                assert mapped[:] == old_bytes, 'packaging changed an already-mapped code image'
                assert os.fstat(loaded.fileno()).st_ino == old_inode
                assert destination.stat().st_ino != old_inode
                assert destination.read_bytes() == new_bytes
                assert destination.stat().st_mode & 0o777 == 0o755
                # A second incremental build must preserve both older mappings.
                with destination.open('rb') as second:
                    with mmap.mmap(second.fileno(), 0, access=mmap.ACCESS_READ) as second_map:
                        origin.write_bytes(b'third image')
                        package.copy_runtime_image(origin, destination)
                        assert second_map[:] == new_bytes
                        assert mapped[:] == old_bytes
                        assert destination.read_bytes() == b'third image'
        assert set(path.name for path in work.iterdir()) == {'new.dylib', 'loaded.dylib'}
    print('PASS: repeated packaging preserves mapped images, replaces contents and retains executable mode')


if __name__ == '__main__':
    main()
