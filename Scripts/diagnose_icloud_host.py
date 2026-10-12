#!/usr/bin/env python3
"""Read-only iCloud host/signature diagnostics; never launches the host.

Only manifest, signed executable metadata and crash termination metadata are
reported. Does not inspect a browser Profile, native messages or password data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXTENSION = 'pejdijmoenmkgeppbflobdenhhabjlaj'
ENTITLEMENT = 'com.apple.developer.web-browser.public-key-credential'


def signature_info(path):
    result = subprocess.run(['codesign', '-dvvv', '--entitlements', '-', str(path)],
                            capture_output=True, text=True, check=True)
    text = result.stdout + result.stderr
    facts = {}
    for key in ('Identifier', 'TeamIdentifier', 'CDHash'):
        match = re.search(r'^' + key + r'=(.*)$', text, re.MULTILINE)
        facts[key] = match.group(1) if match else None
    # Modern codesign prints the DER entitlement dictionary in this format.
    # An unrecognized representation remains unknown, never a false rejection.
    if '[Dict]' in text:
        facts['browser_entitlement'] = bool(re.search(
            r'\[Key\]\s+' + re.escape(ENTITLEMENT) +
            r'\s+\[Value\]\s+\[Bool\]\s+true', text))
    else:
        facts['browser_entitlement'] = None
    return facts


def parent_constraints(path):
    """Extract slot 9 of Apple's signed Mach-O, without modifying the file."""
    data = path.read_bytes()
    slices = [0]
    magic, = struct.unpack_from('>I', data)
    if magic == 0xcafebabe:
        count, = struct.unpack_from('>I', data, 4)
        slices = [struct.unpack_from('>IIIII', data, 8 + 20 * i)[2]
                  for i in range(count)]
    results = []
    for offset in slices:
        magic, cpu, subtype, _, count, _, _, _ = struct.unpack_from('<8I', data, offset)
        if magic != 0xfeedfacf or cpu != 0x100000c:
            continue
        command = offset + 32
        for _ in range(count):
            kind, length = struct.unpack_from('<II', data, command)
            if kind == 0x1d:  # LC_CODE_SIGNATURE
                relative, _ = struct.unpack_from('<II', data, command + 8)
                signature = offset + relative
                _, _, slots = struct.unpack_from('>III', data, signature)
                for i in range(slots):
                    slot, relative = struct.unpack_from('>II', data, signature + 12 + i * 8)
                    if slot != 9:  # CSSLOT_LAUNCH_CONSTRAINT_PARENT
                        continue
                    blob = signature + relative
                    blob_magic, blob_length = struct.unpack_from('>II', data, blob)
                    if blob_magic != 0xfade8181:
                        raise ValueError('unrecognized signed launch constraint blob')
                    der = data[blob + 8:blob + blob_length]
                    with tempfile.TemporaryDirectory(prefix='cio-apple-constraint-') as directory:
                        source = Path(directory) / 'parent.der'
                        source.write_bytes(der)
                        parsed = subprocess.run(['openssl', 'asn1parse', '-inform', 'DER',
                                                 '-in', str(source), '-i'],
                                                capture_output=True, text=True, check=True).stdout
                    # All values here are the helper's public signed constraints.
                    strings = re.findall(r'UTF8STRING\s+:([^\n]+)', parsed)
                    results.append({'cpu_subtype': subtype,
                                    'sha256': hashlib.sha256(der).hexdigest(),
                                    'signed_constraint_strings': strings,
                                    'asn1': parsed})
            command += length
    return results


def crash_metadata(directory):
    records = []
    for path in sorted(directory.glob('PasswordManagerBrowserExtensionHelper-*.ips'))[-12:]:
        try:
            text = path.read_text()
            record = json.loads(text.split('\n', 1)[1])
        except (OSError, ValueError, IndexError):
            continue
        if record.get('parentProc') != 'Cio':
            continue
        records.append({'report': path.name, 'time': record.get('captureTime'),
                        'pid': record.get('pid'), 'parent': record.get('parentProc'),
                        'parent_pid': record.get('parentPid'),
                        'signal': record.get('exception', {}).get('signal'),
                        'signing_id': record.get('codeSigningID')})
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path,
                        default=ROOT / 'build/DerivedData/Build/Products/Debug/Cio.app')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    manifest_path = Path('/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json')
    manifest = json.loads(manifest_path.read_text())
    executable = Path(manifest['path'])
    info = {
        'manifest': str(manifest_path), 'host': manifest['name'],
        'official_extension_origin_allowed':
            f'chrome-extension://{EXTENSION}/' in manifest['allowed_origins'],
        'helper': str(executable), 'helper_signature': signature_info(executable),
        'cio_signature': signature_info(args.app),
        'parent_constraints': parent_constraints(executable),
        'cio_parent_crashes': crash_metadata(Path.home() / 'Library/Logs/DiagnosticReports'),
        'note': 'Read-only evidence; signed constraints are not an authorization grant. '
                'No helper launch, pairing, Profile or password access.',
    }
    output = json.dumps(info, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + '\n')
    # Keep console output small; the artifact retains the exact signed ASN.1.
    for item in info['parent_constraints']:
        item.pop('asn1')
    print(json.dumps(info, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
