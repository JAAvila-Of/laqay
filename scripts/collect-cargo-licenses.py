"""Collect package license texts from a cargo metadata JSON file, without builds."""

import json
from pathlib import Path
import sys


def collect(metadata):
    sections = [
        "Laqay: third-party Cargo license notices",
        "Includes resolved build and target-specific packages, not only linked code.",
        "Compiler toolchain and operating-system components have separate terms.",
    ]
    for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
        if package["source"] is None:
            continue
        root = Path(package["manifest_path"]).parent
        files = {
            path for path in root.rglob("*") if path.is_file() and (
                path.name.lower().startswith(("license", "licence", "copying", "copyright"))
                or path.name.lower() in ("notice", "unlicense")
            )
        }
        if package.get("license_file"):
            files.add(root / package["license_file"])
        if not files:
            raise ValueError(f"No license text found for {package['name']} {package['version']}")
        sections.append(
            f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
            f"Declared license: {package.get('license') or 'see license file'}"
        )
        for path in sorted(files):
            sections.append(f"\n--- {path.relative_to(root).as_posix()} ---\n")
            sections.append(path.read_text(encoding="utf-8"))
    return "\n".join(sections) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: collect-cargo-licenses.py <metadata.json> <output.txt>")
    metadata = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    Path(sys.argv[2]).write_text(collect(metadata), encoding="utf-8")
