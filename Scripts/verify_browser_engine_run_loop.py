#!/usr/bin/env python3
"""Exercise the production Swift host driver with the actual Chromium UI pump.

Runs an isolated Foundation/AppKit harness, without launching the browser app.
"""
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/ChromiumBuild/src"
OUT = SOURCE / "out/CioDev"
WORK = ROOT / "build/verification/browser-engine-run-loop"


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    variables = {}
    for line in (OUT / "obj/chrome/chrome_dll.ninja").read_text().splitlines():
        if " = " in line and not line.startswith(" "):
            key, value = line.split(" = ", 1)
            variables[key] = value.replace("$ ", " ")
    flags = []
    for name in ("defines", "include_dirs", "cflags", "cflags_objcc"):
        flags += shlex.split(variables[name])
    standalone = []
    index = 0
    while index < len(flags):
        flag = flags[index]
        if flag == "-Xclang" and flags[index + 1].startswith("-fmodule"):
            index += 2
            continue
        if not flag.startswith("-fmodule") and flag != "-DUSE_LIBCXX_MODULES":
            standalone.append(flag)
        index += 1
    sysroot = flags[flags.index("-isysroot") + 1]
    include = WORK / "include/chrome/browser/ui"
    include.mkdir(parents=True, exist_ok=True)
    link = include / "cio"
    if not link.exists():
        link.symlink_to(ROOT / "Engine/CioChromium/Native", target_is_directory=True)
    compiler = SOURCE / "third_party/llvm-build/Release+Asserts/bin/clang++"
    objects = []
    for relative in ("Engine/CioChromium/Tests/HostedRunLoopFixture.mm",
                     "Engine/CioChromium/Native/CioHostedMessagePump.mm"):
        obj = WORK / (Path(relative).stem + ".o")
        subprocess.run([str(compiler), "-I" + str(WORK / "include"),
                        *standalone, "-I" + str(ROOT), "-c", str(ROOT / relative),
                        "-o", str(obj)], cwd=OUT, check=True)
        objects.append(str(obj))
    library = WORK / "libCioRunLoopFixture.dylib"
    subprocess.run([str(compiler), *objects, "-dynamiclib", "-o", str(library),
                    "-nostdlib++", "-isysroot", sysroot,
                    "-L" + str(OUT), "-lbase", "-lc++_chrome",
                    "-lbase_allocator_partition_allocator_src_partition_alloc_raw_ptr",
                    "-framework", "AppKit", "-framework", "CoreFoundation",
                    "-Wl,-rpath," + str(OUT)], cwd=OUT, check=True)
    executable = WORK / "BrowserEngineRunLoopTest"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", str(WORK / "module-cache"),
                    str(ROOT / "Cio/App/BrowserEngineRunLoopDriver.swift"),
                    str(ROOT / "Engine/CioChromium/Tests/BrowserEngineRunLoopTest.swift"),
                    str(library), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == "__main__":
    main()
