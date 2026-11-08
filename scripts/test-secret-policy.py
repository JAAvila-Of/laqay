"""Exercise the real scanner against isolated, synthetic secret fixtures."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    scanner = str(Path(sys.argv[1]).resolve())
    fixed = "0123456789abcdef" * 2
    changed = "".join(chr(code) for code in (
        55, 77, 120, 57, 97, 75, 50, 112, 82, 56, 116, 86, 52, 98, 78, 54,
        99, 72, 49, 119, 74, 53, 100, 81, 51, 121, 76, 48, 101, 83, 103, 90,
    ))
    cases = [
        ("scripts/Test-ShareHarnessPreparation.ps1", fixed, False),
        ("scripts/Test-StorageHarnessPreparation.ps1", fixed, False),
        ("scripts/Test-ShareHarnessPreparation.ps1", changed, True),
        ("scripts/Test-StorageHarnessPreparation.ps1", changed, True),
        ("scripts/another-file.ps1", fixed, True),
    ]
    for index, (name, value, expected) in enumerate(cases):
        with tempfile.TemporaryDirectory(prefix="laqay-secret-policy-") as temp:
            work = Path(temp)
            source = work / "source"
            fixture = source / name
            fixture.parent.mkdir(parents=True)
            fixture.write_text("$token='" + value + "'\n", encoding="utf-8")
            report = work / "report.json"
            result = subprocess.run([
                scanner, "dir", str(source), "--config", str(ROOT / ".gitleaks.toml"),
                "--redact=100", "--ignore-gitleaks-allow", "--no-banner",
                "--report-format=json", "--report-path", str(report),
            ], capture_output=True, text=True, timeout=30, cwd=work)
            if result.returncode not in (0, 1) or not report.is_file():
                raise RuntimeError(f"Scanner execution failed in case {index}")
            findings = json.loads(report.read_text(encoding="utf-8"))
            detected = any(item["RuleID"] == "generic-api-key" for item in findings)
            if detected != expected or bool(result.returncode) != expected:
                raise AssertionError(f"Secret policy regression in case {index}")
    print(f"Secret policy: {len(cases)} real-scanner cases passed using synthetic data.")


if __name__ == "__main__":
    main()
