#!/usr/bin/env python3
"""Test generated password drain bodies against the pinned Chromium base ABI.

No overlay preparation, engine build, browser launch, Profile, or credential
access. Only the method surroundings and marker writes are synthetic.
"""
import hashlib
import json
from pathlib import Path
import re
import resource
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/ChromiumBuild/src"
OUT = SOURCE / "out/CioDev"
WORK = ROOT / "build/verification/password-shutdown"
STORE_DIR = SOURCE / "components/password_manager/core/browser/password_store"


def extract_method(text, signature):
    if text.count(signature) != 1:
        raise RuntimeError(f"Expected one generated {signature}; regenerate the overlay first")
    start = text.index(signature)
    opening = text.index("{", start)
    # Ignore comments and quoted literals so their braces cannot truncate a body.
    tokens = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', re.S)
    depth = 0
    for token in tokens.finditer(text, opening):
        if token.group() == "{":
            depth += 1
        elif token.group() == "}":
            depth -= 1
            if depth == 0:
                return text[start:token.end()]
    raise RuntimeError(f"Unterminated generated method: {signature}")


def toolchain_flags():
    variables = {}
    for line in (OUT / "obj/chrome/chrome_dll.ninja").read_text().splitlines():
        if " = " in line and not line.startswith(" "):
            key, value = line.split(" = ", 1)
            variables[key] = value.replace("$ ", " ")
    flags = []
    for name in ("defines", "include_dirs", "cflags", "cflags_cc"):
        flags.extend(shlex.split(variables[name]))
    standalone = []
    index = 0
    while index < len(flags):
        flag = flags[index]
        if flag == "-Xclang" and index + 1 < len(flags) and flags[index + 1].startswith("-fmodule"):
            index += 2
            continue
        if not flag.startswith("-fmodule") and flag != "-DUSE_LIBCXX_MODULES":
            standalone.append(flag)
        index += 1
    return standalone


def compile_test(directory, methods, flags):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "PasswordShutdownMethods.inc").write_text("\n\n".join(methods) + "\n")
    compiler = SOURCE / "third_party/llvm-build/Release+Asserts/bin/clang++"
    obj = directory / "PasswordShutdownTest.o"
    subprocess.run([str(compiler), *flags, "-I" + str(directory), "-c",
                    str(ROOT / "Engine/CioChromium/Tests/PasswordShutdownTest.cc"),
                    "-o", str(obj)], cwd=OUT, check=True)
    executable = directory / "PasswordShutdownTest"
    sysroot = flags[flags.index("-isysroot") + 1]
    subprocess.run([str(compiler), str(obj), "-o", str(executable),
                    "-nostdlib++", "-isysroot", sysroot, "-L" + str(OUT),
                    "-lbase", "-lc++_chrome", "-lthird_party_perfetto_libperfetto",
                    "-lbase_allocator_partition_allocator_src_partition_alloc_raw_ptr",
                    "-framework", "CoreFoundation", "-Wl,-rpath," + str(OUT)],
                   cwd=OUT, check=True)
    return executable


def disable_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    marker = json.loads((SOURCE / ".cio-source.json").read_text())
    pinned = json.loads((ROOT / "Engine/Chromium/upstreams.json").read_text())["engine"]
    if marker["version"] != pinned["version"] or marker["sha256"] != pinned["source_sha256"]:
        raise RuntimeError("Password shutdown test requires the repository's pinned Chromium source")
    requests = [
        ("password_store.cc", "void PasswordStore::FlushForShutdown("),
        ("password_store_built_in_backend.cc", "void PasswordStoreBuiltInBackend::FlushForShutdown("),
        ("password_store.cc", "void PasswordStore::OnInitCompleted("),
        ("password_store.cc", "void PasswordStore::OnUnblocklistCompleted("),
    ]
    snapshots = {name: (STORE_DIR / name).read_text() for name, _ in requests}
    methods = [extract_method(snapshots[name], signature) for name, signature in requests]
    WORK.mkdir(parents=True, exist_ok=True)
    manifest = {
        "version": marker["version"],
        "methods": [{"source": str(STORE_DIR / name), "signature": signature,
                     "sha256": hashlib.sha256(method.encode()).hexdigest()}
                    for (name, signature), method in zip(requests, methods)],
    }
    (WORK / "extracted-methods.json").write_text(json.dumps(manifest, indent=2) + "\n")
    flags = toolchain_flags()
    executable = compile_test(WORK, methods, flags)
    result = subprocess.run([str(executable)], capture_output=True, text=True,
                            timeout=20, preexec_fn=disable_core_dump)
    log = WORK / "shutdown-tests.log"
    log.write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        raise RuntimeError(f"Password shutdown test failed ({result.returncode}); see {log}")
    output = result.stdout

    # Negative controls prove ordering assertions reject early replies, missing
    # initialization/compound deferral, and reversed completion ordering. The
    # primary executable above always uses unchanged generated bodies.
    early_backend = methods.copy()
    early_backend[1] = methods[1][:methods[1].index("{") + 1] + "\n  std::move(completion).Run(true);\n}"
    premature_store = methods.copy()
    guard = "  if (post_init_callback_) {"
    block = extract_method(methods[0], guard)
    premature_store[0] = methods[0].replace(block, "", 1)
    premature_compound = methods.copy()
    compound_guard = extract_method(methods[0], "  if (pending_unblocklists_) {")
    premature_compound[0] = methods[0].replace(compound_guard, "", 1)
    reversed_completion = methods.copy()
    original_callback = "  if (completion) std::move(completion).Run();"
    if methods[3].count(original_callback) != 1:
        raise RuntimeError("Compound completion changed; update the negative-control mutation")
    without_callback = methods[3].replace(original_callback, "", 1)
    closing = without_callback.rindex("}")
    reversed_completion[3] = (without_callback[:closing] + original_callback + "\n" +
                              without_callback[closing:])
    for name, bodies, mode, assertion in (
        ("early-backend-reply", early_backend, "--initialized", "flush completed before write release"),
        ("missing-init-deferral", premature_store, "--deferred", "flush completed before write release"),
        ("missing-compound-deferral", premature_compound, "--compound",
         "flush was not deferred behind outstanding compound operations"),
        ("reversed-compound-completion", reversed_completion, "--compound",
         "flush started before original compound completion"),
    ):
        faulty = compile_test(WORK / name, bodies, flags)
        failure = subprocess.run([str(faulty), mode], capture_output=True, text=True,
                                 timeout=20, preexec_fn=disable_core_dump)
        (WORK / (name + ".log")).write_text(failure.stdout + failure.stderr)
        if failure.returncode >= 0 or assertion not in failure.stderr:
            raise RuntimeError(f"Negative control did not hit the ordering assertion: {name}")
        output += f"PASS: negative control rejects {name}\n"
    for name, original in snapshots.items():
        if (STORE_DIR / name).read_text() != original:
            raise RuntimeError("Generated methods changed during verification; rerun after regeneration")
    (WORK / "shutdown-tests.log").write_text(output + result.stderr)
    print(output, end="")


if __name__ == "__main__":
    main()
