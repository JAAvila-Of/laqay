"""Validate the portable archive without executing the application."""

import argparse
import hashlib
from pathlib import Path
import struct
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = {
    "LICENSE": ROOT / "LICENSE",
    "THIRD_PARTY_NOTICES.md": ROOT / "THIRD_PARTY_NOTICES.md",
    "TRADEMARKS.md": ROOT / "TRADEMARKS.md",
    "PORTABLE.md": ROOT / "docs/PORTABLE.md",
}


def check_pe(data):
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("Missing DOS executable header")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset < 64 or offset + 94 > len(data):
        raise ValueError("Truncated PE header")
    if data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("Missing PE signature")
    machine, = struct.unpack_from("<H", data, offset + 4)
    optional_size, flags = struct.unpack_from("<HH", data, offset + 20)
    magic, = struct.unpack_from("<H", data, offset + 24)
    subsystem, = struct.unpack_from("<H", data, offset + 92)
    if (machine != 0x8664 or magic != 0x20B or subsystem != 2
            or optional_size < 70 or offset + 24 + optional_size > len(data)
            or not flags & 2 or flags & 0x2000):
        raise ValueError("Expected an AMD64 PE32+ GUI executable, not a DLL")


def checksum_text(binary, archive):
    return "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in (binary, archive)
    )


def check(binary, archive, licenses, checksums):
    if binary.name != "laqay.exe" or archive.name != "laqay-windows-x86_64.zip":
        raise ValueError("Unexpected executable or archive name")
    expected = {name: path.read_bytes() for name, path in DOCUMENTS.items()}
    expected["laqay.exe"] = binary.read_bytes()
    expected["THIRD_PARTY_LICENSES.txt"] = licenses.read_bytes()
    if any(not data.strip() for data in expected.values()):
        raise ValueError("Empty distribution file")
    check_pe(expected["laqay.exe"])
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if len(entries) != len(expected) or {item.filename for item in entries} != set(expected):
            raise ValueError("Unexpected, duplicate, or missing archive entries")
        for item in entries:
            source = expected[item.filename]
            if item.is_dir() or item.file_size != len(source) or package.read(item) != source:
                raise ValueError(f"Archive content mismatch: {item.filename}")
    # Accept the CRLF produced by Windows PowerShell, but no extra entries.
    if checksums.read_text(encoding="ascii") != checksum_text(binary, archive):
        raise ValueError("SHA256SUMS.txt does not match the executable and archive")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--licenses", required=True, type=Path)
    parser.add_argument("--checksums", required=True, type=Path)
    args = parser.parse_args()
    check(args.binary, args.archive, args.licenses, args.checksums)
    print("Portable archive, AMD64 GUI header, notices, and SHA-256 checksums passed.")


if __name__ == "__main__":
    main()
