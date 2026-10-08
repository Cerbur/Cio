#!/usr/bin/env python3
"""Compile the actual hosted pump against the pinned Chromium base library."""
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/ChromiumBuild/src"
OUT = SOURCE / "out/CioDev"
WORK = ROOT / "build/verification/hosted-message-pump"


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    # Read the already-generated toolchain flags without enumerating Ninja's
    # entire dependency tree. This keeps libc++, ABI and DCHECK settings equal
    # to the library used by the app.
    variables = {}
    for line in (OUT / "obj/chrome/chrome_dll.ninja").read_text().splitlines():
        if " = " in line and not line.startswith(" "):
            key, value = line.split(" = ", 1)
            variables[key] = value.replace("$ ", " ")
    compiler = SOURCE / "third_party/llvm-build/Release+Asserts/bin/clang++"
    flags = []
    for name in ("defines", "include_dirs", "cflags", "cflags_objcc"):
        flags += shlex.split(variables[name])
    # The standalone harness does not consume Chrome's precompiled modules.
    standalone_flags = []
    index = 0
    while index < len(flags):
        flag = flags[index]
        if flag == "-Xclang" and flags[index + 1].startswith("-fmodule"):
            index += 2
            continue
        if not flag.startswith("-fmodule") and flag != "-DUSE_LIBCXX_MODULES":
            standalone_flags.append(flag)
        index += 1
    flags = standalone_flags
    sysroot = flags[flags.index("-isysroot") + 1]
    objects = []
    # Include the tracked implementation, even before the overlay is rebuilt.
    include = WORK / "include/chrome/browser/ui"
    include.mkdir(parents=True, exist_ok=True)
    link = include / "cio"
    if not link.exists():
        link.symlink_to(ROOT / "Engine/CioChromium/Native", target_is_directory=True)
    for relative in ("Engine/CioChromium/Tests/HostedMessagePumpTest.mm",
                     "Engine/CioChromium/Native/CioHostedMessagePump.mm"):
        obj = WORK / (Path(relative).stem + ".o")
        subprocess.run([str(compiler), "-I" + str(WORK / "include"),
                        *flags, "-I" + str(ROOT), "-c", str(ROOT / relative),
                        "-o", str(obj)], cwd=OUT, check=True)
        objects.append(str(obj))
    executable = WORK / "HostedMessagePumpTest"
    subprocess.run([str(compiler), *objects, "-o", str(executable),
                    "-nostdlib++", "-isysroot", sysroot,
                    "-L" + str(OUT), "-lbase", "-lc++_chrome",
                    "-lbase_allocator_partition_allocator_src_partition_alloc_raw_ptr",
                    "-framework", "AppKit",
                    "-framework", "CoreFoundation", "-Wl,-rpath," + str(OUT)],
                   cwd=OUT, check=True)
    subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
