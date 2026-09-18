#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pack Potuzhno IPA: replace Frameworks/Mods.dylib and rebrand display strings.

Never touch CFBundleExecutable / bundle identifiers — signers look up
Payload/MAX.app/MAX by the executable name in Info.plist.
"""
from __future__ import annotations

import io
import plistlib
import re
import struct
import sys
import zipfile
from pathlib import Path

IPA_SRC = Path(r"C:\rev\rev\Potuzhno_v12_1_FINAL.ipa")
DYLIB_SRC = Path(r"C:\Users\ll\Desktop\max-tweak\MAXMods.dylib")
IPA_OUT = Path(r"C:\Users\ll\Desktop\max-tweak\Potuzhno_v12_4_FULLLOG.ipa")
MEMBER = "Payload/MAX.app/Frameworks/Mods.dylib"
MH_MAGIC_64 = 0xFEEDFACF

TOKEN_RE = re.compile(
    r"(?<![A-Za-zА-Яа-яЁё0-9_])(MAX|Max|макс|Макс|МАКС)(?![A-Za-zА-Яа-яЁё0-9_])"
)

# Keys we may rewrite on the MAIN app / localization files only.
DISPLAY_KEYS = {"CFBundleDisplayName", "CFBundleName"}
USAGE_KEYS = {
    "NSCameraUsageDescription",
    "NSContactsUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSPhotoLibraryUsageDescription",
}
NEVER_TOUCH = {
    "CFBundleExecutable",
    "CFBundleIdentifier",
    "CFBundlePackageType",
    "AppIdentifierPrefix",
}


def assert_arm64_dylib(path: Path) -> None:
    data = path.read_bytes()[:32]
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a thin arm64 Mach-O: {path} magic={hex(magic)}")
    filetype = struct.unpack_from("<I", data, 12)[0]
    if filetype != 6:  # MH_DYLIB
        raise SystemExit(f"not MH_DYLIB: {path} filetype={filetype}")


def rebrand_text(s: str) -> str:
    if not isinstance(s, str) or len(s) < 3:
        return s
    return TOKEN_RE.sub("Потужно", s)


def is_main_app_plist(name: str) -> bool:
    n = name.replace("\\", "/")
    return n == "Payload/MAX.app/Info.plist"


def is_app_lproj_strings(name: str) -> bool:
    n = name.replace("\\", "/").lower()
    if "/frameworks/" in n or "/plugins/" in n:
        return False
    return n.endswith("infoplist.strings")


def is_extension_info_plist(name: str) -> bool:
    n = name.replace("\\", "/").lower()
    return "/plugins/" in n and n.endswith("info.plist") and n.count("/") <= 5


def mutate_plist(name: str, plist):
    """Return a new object or the same object if unchanged."""
    if not isinstance(plist, dict):
        return plist
    out = dict(plist)
    changed = False

    if is_main_app_plist(name) or is_app_lproj_strings(name):
        for k in DISPLAY_KEYS:
            if k in out and isinstance(out[k], str):
                if out[k] != "Потужно":
                    out[k] = "Потужно"
                    changed = True
        for k in USAGE_KEYS:
            if k in out and isinstance(out[k], str):
                branded = rebrand_text(out[k])
                if branded != out[k]:
                    out[k] = branded
                    changed = True
        alt = out.get("INAlternativeAppNames")
        if isinstance(alt, list):
            na = []
            for item in alt:
                if isinstance(item, dict):
                    im = dict(item)
                    if isinstance(im.get("INAlternativeAppName"), str):
                        im["INAlternativeAppName"] = "Потужно"
                    na.append(im)
                else:
                    na.append(item)
            if na != alt:
                out["INAlternativeAppNames"] = na
                changed = True
        return out if changed else plist

    if is_extension_info_plist(name) or name.lower().endswith("infoplist.strings"):
        # Extensions: only usage-description tokens, never executable / id.
        for k, v in list(out.items()):
            if k in NEVER_TOUCH:
                continue
            if k in USAGE_KEYS and isinstance(v, str):
                branded = rebrand_text(v)
                if branded != v:
                    out[k] = branded
                    changed = True
            elif k in DISPLAY_KEYS and isinstance(v, str) and TOKEN_RE.search(v):
                out[k] = TOKEN_RE.sub("Потужно", v)
                changed = True
        return out if changed else plist

    return plist


def maybe_rebrand_plist(name: str, data: bytes) -> bytes | None:
    lower = name.replace("\\", "/").lower()
    if "/frameworks/" in lower:
        return None
    if not (
        is_main_app_plist(name)
        or is_app_lproj_strings(name)
        or is_extension_info_plist(name)
        or (lower.endswith("infoplist.strings") and "/frameworks/" not in lower)
    ):
        return None
    try:
        plist = plistlib.loads(data)
    except Exception:
        return None
    branded = mutate_plist(name, plist)
    if branded is plist:
        return None
    fmt = plistlib.FMT_BINARY if data[:8] == b"bplist00" else plistlib.FMT_XML
    buf = io.BytesIO()
    plistlib.dump(branded, buf, fmt=fmt, sort_keys=False)
    return buf.getvalue()


def pack(ipa_src: Path, dylib: Path, ipa_out: Path) -> None:
    if not ipa_src.exists():
        raise SystemExit(f"missing IPA: {ipa_src}")
    if not dylib.exists():
        raise SystemExit(f"missing dylib: {dylib}")
    assert_arm64_dylib(dylib)
    dylib_bytes = dylib.read_bytes()

    replaced = False
    mutated = 0
    tmp = ipa_out.with_suffix(".ipa.tmp")
    if tmp.exists():
        tmp.unlink()

    with zipfile.ZipFile(ipa_src, "r") as zin, zipfile.ZipFile(
        tmp, "w", zipfile.ZIP_DEFLATED
    ) as zout:
        for info in zin.infolist():
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = info.external_attr
            zi.create_system = info.create_system
            zi.flag_bits = info.flag_bits
            if info.extra:
                zi.extra = info.extra

            if info.filename == MEMBER:
                zout.writestr(zi, dylib_bytes)
                replaced = True
                continue

            raw = zin.read(info.filename)
            new = maybe_rebrand_plist(info.filename, raw)
            if new is not None:
                zout.writestr(zi, new)
                mutated += 1
                continue
            zout.writestr(zi, raw)

    if not replaced:
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"{MEMBER} not found in {ipa_src.name}")

    tmp.replace(ipa_out)
    print(f"OK  {ipa_out}")
    print(f"    size {ipa_out.stat().st_size / 1024 / 1024:.1f} MB")
    print(f"    Mods.dylib <- {dylib.name} ({len(dylib_bytes)} bytes)")
    print(f"    rebranded plists: {mutated}")


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else IPA_SRC
    dylib = Path(sys.argv[2]) if len(sys.argv) > 2 else DYLIB_SRC
    out = Path(sys.argv[3]) if len(sys.argv) > 3 else IPA_OUT
    pack(src, dylib, out)
