#!/usr/bin/env python3
"""Help relocate a Tcl 9 dylib that has its zipfs ZIP appended after the Mach-O.

install_name_tool / codesign refuse such files ("__LINKEDIT segment does not
cover the end of the file"), so the packaging splits off the trailing ZIP,
relocates the clean Mach-O, then re-attaches the ZIP.  This tool provides the
two byte-exact operations that shell can't do reliably:

    macho_zipfs.py end      <file>   print the byte offset where the Mach-O ends
                                     (== where the appended ZIP begins)
    macho_zipfs.py validate <file>   exit 0 iff the appended ZIP is intact
                                     (every entry's CRC verifies)

Only thin (single-arch) little-endian Mach-O is handled -- the from-source Tcl
build produces thin arm64 / x86_64 dylibs.  A fat binary exits non-zero so the
caller falls back to leaving the file untouched.
"""
import struct
import sys
import zipfile

LC_SEGMENT     = 0x01
LC_SEGMENT_64  = 0x19
MH_MAGIC_64    = 0xFEEDFACF
MH_MAGIC_32    = 0xFEEDFACE


def macho_end(path):
    """Byte offset one past the last file byte the Mach-O describes."""
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 32:
        raise SystemExit("too small to be a Mach-O")
    magic = struct.unpack("<I", data[:4])[0]
    if magic == MH_MAGIC_64:
        cmd_off = 32
    elif magic == MH_MAGIC_32:
        cmd_off = 28
    else:
        raise SystemExit("not a thin little-endian Mach-O (magic=0x%08x)" % magic)
    ncmds = struct.unpack("<I", data[16:20])[0]
    end = 0
    off = cmd_off
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == LC_SEGMENT_64:
            fileoff, filesize = struct.unpack("<QQ", data[off + 40:off + 56])
            end = max(end, fileoff + filesize)
        elif cmd == LC_SEGMENT:
            fileoff, filesize = struct.unpack("<II", data[off + 32:off + 40])
            end = max(end, fileoff + filesize)
        off += cmdsize
    if end <= 0 or end > len(data):
        raise SystemExit("bad Mach-O segment table")
    return end


def validate(path):
    """Verify the appended ZIP (zipfile auto-corrects for the Mach-O prefix)."""
    with zipfile.ZipFile(path) as zf:
        bad = zf.testzip()
    if bad is not None:
        raise SystemExit("ZIP CRC FAILED on entry: %s" % bad)


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    op, path = argv[1], argv[2]
    if op == "end":
        print(macho_end(path))
    elif op == "validate":
        validate(path)
        print("ZIP CRC OK")
    else:
        raise SystemExit("unknown op: %s" % op)


if __name__ == "__main__":
    main(sys.argv)
