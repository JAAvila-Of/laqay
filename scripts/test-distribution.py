"""Exercise archive rejection and the Windows packaging command with inert bytes."""

import importlib.util
from pathlib import Path
import os
import struct
import subprocess
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("distribution", Path(__file__).with_name("check-distribution.py"))
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.root / "laqay.exe"
        self.archive = self.root / "laqay-windows-x86_64.zip"
        self.licenses = self.root / "THIRD_PARTY_LICENSES.txt"
        self.checksums = self.root / "SHA256SUMS.txt"
        # A header fixture only: never launched or treated as a runnable program.
        data = bytearray(512)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<H", data, 132, 0x8664)
        struct.pack_into("<HHH", data, 148, 240, 2, 0x20B)
        struct.pack_into("<H", data, 220, 2)
        self.binary.write_bytes(data)
        self.licenses.write_text("Original dependency notice.\n", encoding="utf-8")
        self.entries = {name: path.read_bytes() for name, path in distribution.DOCUMENTS.items()}
        self.entries.update({"laqay.exe": data, "THIRD_PARTY_LICENSES.txt": self.licenses.read_bytes()})

    def package(self):
        with zipfile.ZipFile(self.archive, "w") as package:
            for name, data in self.entries.items():
                package.writestr(name, data)
        self.checksums.write_text(distribution.checksum_text(self.binary, self.archive), encoding="ascii", newline="\n")

    def check(self):
        distribution.check(self.binary, self.archive, self.licenses, self.checksums)

    def test_matching_package_and_crlf_checksums(self):
        self.package()
        self.checksums.write_bytes(self.checksums.read_bytes().replace(b"\n", b"\r\n"))
        self.check()

    def test_missing_added_and_changed_entries(self):
        original = dict(self.entries)
        for mutation in ("missing", "extra", "changed", "path"):
            with self.subTest(mutation=mutation):
                self.entries = dict(original)
                if mutation == "missing":
                    del self.entries["LICENSE"]
                elif mutation == "extra":
                    self.entries["private.log"] = b"unexpected"
                elif mutation == "path":
                    self.entries["../LICENSE"] = self.entries.pop("LICENSE")
                else:
                    self.entries["laqay.exe"] = b"different executable"
                self.package()
                with self.assertRaises(ValueError):
                    self.check()

    def test_duplicate_and_corrupt_entries(self):
        self.package()
        with zipfile.ZipFile(self.archive, "a") as package:
            # ZIP permits duplicate names; the distribution contract does not.
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                package.writestr("LICENSE", self.entries["LICENSE"])
        with self.assertRaises(ValueError):
            self.check()
        self.archive.write_bytes(b"not a ZIP")
        with self.assertRaises(zipfile.BadZipFile):
            self.check()

    def test_changed_archive_hash_and_empty_notice(self):
        self.package()
        self.checksums.write_text("0" * 64 + "  laqay.exe\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            self.check()
        self.licenses.write_bytes(b" ")
        with self.assertRaisesRegex(ValueError, "Empty"):
            self.check()

    def test_wrong_architecture_console_dll_and_truncated_header(self):
        original = self.binary.read_bytes()
        for offset, value in ((132, 0x14C), (152, 0x10B), (220, 3), (150, 0x2002)):
            with self.subTest(offset=offset):
                data = bytearray(original)
                struct.pack_into("<H", data, offset, value)
                with self.assertRaises(ValueError):
                    distribution.check_pe(data)
        with self.assertRaises(ValueError):
            distribution.check_pe(original[:200])

    @unittest.skipUnless(os.name == "nt", "PowerShell packaging runs on Windows")
    def test_actual_packaging_command_with_inert_fixture(self):
        output = self.root / "package output"
        subprocess.run([
            "powershell.exe", "-NoProfile", "-NonInteractive", "-File",
            str(Path(__file__).with_name("New-Distribution.ps1")),
            "-BinaryPath", str(self.binary), "-LicenseTextPath", str(self.licenses),
            "-OutputDirectory", str(output),
        ], check=True)
        distribution.check(self.binary, output / self.archive.name, self.licenses, output / self.checksums.name)


if __name__ == "__main__":
    unittest.main()
