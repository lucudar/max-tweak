#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pack Potuzhno IPA: replace Frameworks/Mods.dylib and rebrand MAX strings.

The FINAL IPA already has LC_LOAD_DYLIB @executable_path/Frameworks/Mods.dylib.
We keep that load command and only swap the file bytes so the new tweak loads
without a second Mods.dylib (the old v6 swizzle must not ship alongside v12).
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
IPA_OUT = Path(r"C:\Users\ll\Desktop\max-tweak\Potuzhno_v12_3.ipa")
MEMBER = "Payload/MAX.app/Frameworks/Mods.dylib"
MH_MAGIC_64 = 0xFEEDFACF

TOKEN_RE = re.compile(
    r"(?<![A-Za-zА-Яа-яЁё0-9_])(MAX|Max|макс|Макс|МАКС)(?![A-Za-zА-Яа-яЁё0-9_])"
)
PLIST_KEYS = {
    "CFBundleDisplayName",
    "CFBundleName",
    "NSCameraUsageDescription",
    "NSContactsUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSPhotoLibraryUsageDescription",
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


def rebrand_obj(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in PLIST_KEYS and isinstance(v, str):
                if k in ("CFBundleDisplayName", "CFBundleName"):
                    out[k] = "Потужно"
                else:
                    out[k] = rebrand_text(v)
            elif k == "INAlternativeAppNames":
                out[k] = rebrand_obj(v)
            elif k == "INAlternativeAppName" and isinstance(v, str):
                out[k] = "Потужно"
            else:
                out[k] = rebrand_obj(v)
        return out
    if isinstance(obj, list):
        return [rebrand_obj(x) for x in obj]
    if isinstance(obj, str):
        return rebrand_text(obj)
    return obj


def maybe_rebrand_plist(name: str, data: bytes) -> bytes | None:
    lower = name.replace("\\", "/").lower()
    if not (
        lower.endswith("info.plist")
        or lower.endswith("infoplist.strings")
        or lower.endswith("appintentvocabulary.plist")
    ):
        return None
    if "frameworks/" in lower and "cydiasubstrate" not in lower:
        # leave vendor frameworks alone (WebRTC, VPX, …)
        if not lower.endswith("infoplist.strings"):
            return None
    try:
        plist = plistlib.loads(data)
    except Exception:
        return None
    branded = rebrand_obj(plist)
    if branded == plist:
        return None
    fmt = (
        plistlib.FMT_BINARY
        if data[:8] == b"bplist00"
        else plistlib.FMT_XML
    )
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
