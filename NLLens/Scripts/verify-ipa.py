#!/usr/bin/env python3
"""Checks that an .ipa is actually installable before it reaches a phone.

Written after a build that looked perfect and was not: correct Payload
layout, complete Info.plist, real arm64 Mach-O — and Sideloadly rejected it
with "Invalid file". The cause was invisible to every obvious check. The app
had been built with CODE_SIGNING_ALLOWED=NO, which omits the
LC_CODE_SIGNATURE load command entirely, and a re-signing tool *replaces* a
signature rather than adding one: doing it from scratch means expanding the
Mach-O header and relocating __LINKEDIT.

So the structural checks are the cheap part. The load command is the one
that mattered.
"""

import plistlib
import struct
import sys
import zipfile

LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGICS = {0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA}


def fail(message):
    print(f"FAIL: {message}")
    sys.exit(1)


def has_code_signature(binary: bytes) -> bool:
    """Whether the Mach-O carries a signature slot a re-signer can replace."""
    if len(binary) < 32:
        return False

    magic = struct.unpack_from("<I", binary, 0)[0]
    if magic in FAT_MAGICS:
        # A fat binary would need each slice walked. Xcode does not produce
        # one here, so rather than half-support it, say so plainly.
        fail("fat binary — this check only understands a single arm64 slice")
    if magic != MH_MAGIC_64:
        fail(f"not a 64-bit little-endian Mach-O (magic 0x{magic:x})")

    ncmds = struct.unpack_from("<I", binary, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<2I", binary, offset)
        if cmd == LC_CODE_SIGNATURE:
            return True
        if cmdsize == 0:
            break
        offset += cmdsize
    return False


def main(path):
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        fail("not a zip archive")

    names = archive.namelist()

    apps = {n.split("/")[1] for n in names if n.startswith("Payload/") and ".app/" in n}
    if not apps:
        fail("no Payload/<name>.app in the archive")
    if len(apps) > 1:
        fail(f"more than one app in Payload: {sorted(apps)}")
    app = apps.pop()
    print(f"app: {app}")

    # macOS zip happily stores resource forks alongside the real files, and
    # some installers choke on them.
    junk = [n for n in names if "__MACOSX" in n or "/._" in n]
    if junk:
        fail(f"AppleDouble junk in the archive, e.g. {junk[0]}")

    plist_path = f"Payload/{app}/Info.plist"
    if plist_path not in names:
        fail("no Info.plist")
    info = plistlib.loads(archive.read(plist_path))

    for key in ("CFBundleExecutable", "CFBundleIdentifier", "MinimumOSVersion"):
        if not info.get(key):
            fail(f"Info.plist is missing {key}")
    if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        fail("CFBundleSupportedPlatforms does not list iPhoneOS")

    print(f"bundle id: {info['CFBundleIdentifier']}")
    print(f"minimum iOS: {info['MinimumOSVersion']}")

    executable = f"Payload/{app}/{info['CFBundleExecutable']}"
    if executable not in names:
        fail(f"Info.plist names {info['CFBundleExecutable']} but it is not in the bundle")

    binary = archive.read(executable)
    print(f"binary: {len(binary):,} bytes")

    if not has_code_signature(binary):
        fail(
            "the binary has no LC_CODE_SIGNATURE load command.\n"
            "      Sideloadly, AltStore and SideStore replace an existing signature;\n"
            "      none of them can add the load command. Build with\n"
            "      CODE_SIGN_IDENTITY=\"-\" so an ad-hoc signature reserves the slot."
        )
    print("code signature slot: present")
    print("\nOK — this .ipa can be re-signed and installed.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: verify-ipa.py <path to .ipa>")
    main(sys.argv[1])
