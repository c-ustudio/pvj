#!/usr/bin/env python3
"""Release checks for a PVJ .apk or .aab — see docs/RELEASE.md.

    python3 tools/check_android_artifact.py dist/pvj-0.6.0-beta1.apk [more…]

For each artifact:
  * every native library's ELF PT_LOAD segments are 16 KB aligned
    (p_align >= 0x4000) — the Play requirement for targetSdk 35+, and what
    the GoZen rebuild (tools/GOZEN_ANDROID_BUILD.md) exists for;
  * in an .apk, every uncompressed .so also sits at a 16 KB offset in the
    zip (what `zipalign -P 16` checks; the AAB's libs are repacked by Play);
  * the size, and the SHA-256.
Permissions are not read here (that needs aapt2 / bundletool, Windows
binaries on this box): tools/release_build.sh prints them.

Exit status 1 if any .so fails either alignment check.
"""
import hashlib
import struct
import sys
import zipfile

PAGE = 16384


def elf_load_aligns(data: bytes):
    """[(p_align)] of the PT_LOAD segments of an ELF image, [] if not ELF64."""
    if data[:4] != b"\x7fELF" or data[4] != 2:   # ELFCLASS64
        return []
    little = data[5] == 1
    e = "<" if little else ">"
    e_phoff = struct.unpack_from(e + "Q", data, 0x20)[0]
    e_phentsize, e_phnum = struct.unpack_from(e + "HH", data, 0x36)
    out = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from(e + "I", data, off)[0]
        if p_type == 1:   # PT_LOAD
            out.append(struct.unpack_from(e + "Q", data, off + 0x30)[0])
    return out


def local_header_data_offset(zf: zipfile.ZipFile, info: zipfile.ZipInfo) -> int:
    """Where the entry's DATA starts in the file (after the local header)."""
    fp = zf.fp
    fp.seek(info.header_offset)
    # sig, version, flags, method, time, date, crc, csize, usize, nlen, xlen
    fields = struct.unpack("<IHHHHHIIIHH", fp.read(30))
    sig, nlen, xlen = fields[0], fields[9], fields[10]
    assert sig == 0x04034B50
    return info.header_offset + 30 + nlen + xlen


def check(path: str) -> bool:
    ok = True
    print(f"== {path}")
    with open(path, "rb") as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    size = __import__("os").path.getsize(path)
    print(f"   size   {size:,} bytes ({size / 1048576:.1f} MB)")
    print(f"   sha256 {digest.hexdigest()}")
    is_apk = path.lower().endswith(".apk")
    with zipfile.ZipFile(path) as zf:
        sos = [i for i in zf.infolist() if i.filename.endswith(".so")]
        if not sos:
            print("   (no native libraries)")
        for info in sos:
            data = zf.read(info)
            aligns = elf_load_aligns(data)
            elf_ok = bool(aligns) and all(a >= PAGE for a in aligns)
            line = f"   {info.filename}: {len(data) / 1048576:.1f} MB, PT_LOAD align {sorted(set(aligns))}"
            if is_apk:
                stored = info.compress_type == zipfile.ZIP_STORED
                off = local_header_data_offset(zf, info)
                zip_ok = stored and off % PAGE == 0
                line += f", zip {'stored' if stored else 'COMPRESSED'} @ {off} ({'16K-aligned' if off % PAGE == 0 else 'MISALIGNED'})"
                ok &= zip_ok
            ok &= elf_ok
            print(line + ("" if elf_ok else "   <-- ELF NOT 16 KB"))
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    results = [check(p) for p in sys.argv[1:]]
    print("ALL ALIGNED" if all(results) else "ALIGNMENT FAILURES")
    sys.exit(0 if all(results) else 1)
