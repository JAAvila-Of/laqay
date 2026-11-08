<div align="center">
  <img src="assets/laqay.svg" width="72" height="72" alt="Laqay symbol">
  <h1>Laqay</h1>
  <p><strong>Paste it. Save it.</strong></p>
  <p>Clipboard image → PNG in your current Windows Explorer folder.<br>Just press <kbd>Ctrl</kbd> + <kbd>V</kbd>.</p>
  <p>Windows x64 · Portable · MIT</p>
  <p><a href="https://github.com/JAAvila-Of/laqay/releases/latest"><strong>Download for Windows</strong></a> · <a href="docs/PORTABLE.md">Verify &amp; get started</a> · <a href="docs/integration-tests.md">Test coverage</a></p>
</div>

![CI](https://github.com/JAAvila-Of/laqay/actions/workflows/ci.yml/badge.svg?branch=main)

![Illustration: a clipboard image, Ctrl+V, and a PNG saved in an Explorer folder.](assets/paste-flow.svg)

## Three steps. One familiar shortcut.

1. Extract the portable ZIP and launch `laqay.exe`.
2. Copy an image or take a screenshot.
3. Open a physical Explorer folder and press **Ctrl+V**.

Laqay saves `Screenshot_YYYYMMDD_HHMMSS.png` there. Existing files are never
overwritten; filename collisions receive a suffix. Supported images keep their
dimensions and available alpha. The diagram above is an illustration, not an
Explorer screenshot.

| In your workflow | Laqay's behavior |
| --- | --- |
| Image in the clipboard, physical Explorer folder | Save a PNG in that folder |
| Copied files, text, or a virtual-file transfer | Keep native paste behavior |
| Editable field, unsupported format, uncertain or virtual destination | Decline image conversion |
| No account or Internet connection | Operate locally, without telemetry or clipboard history |

## A small tray menu

| Menu item | What it does |
| --- | --- |
| **Enabled** | Turn image saving on or off; the icon becomes gray while disabled |
| **Start with Windows** | Register or remove startup for your account; off by default |
| **Exit** | Remove the tray icon and stop the application |

Keep the executable in a stable location if you enable startup. The
[portable guide](docs/PORTABLE.md) covers download verification, startup,
updates and removal. Normal use does not request administrator privileges.

## Stable release, bounded validation

[Laqay 1.0.0](https://github.com/JAAvila-Of/laqay/releases/tag/v1.0.0) is available
for Windows x64. Its source passed a consolidated isolated guest batch:

| Environment | Passed |
| --- | --- |
| Windows 11 Enterprise evaluation, build 26300 | 37 cases and 20 double-paste rounds |
| Windows 10 Pro 22H2, build 19045, es-MX | 12 cases; native file tabs do not apply |
| RDP between two Windows 11 guests | 17 cases |
| Isolated UNC share | 16 cases |

Actual Windows 11 shutdown with a pending image read also passed, with normal
application exit and verified restoration. CI passed 90 tests, including native
clipboard, publication cancellation, Shell staging, disk-full and SMB recovery.
The published downloads passed independent checksum, package, Windows metadata
and build/release provenance checks and are protected by release immutability.

Coverage is specific to the recorded builds, applications and stages. The final
context check is not atomic with publication. See the
[integration matrix](docs/integration-tests.md) for diagnostic modes, source and
artifact identities, historical package-cycle results and remaining limits.

## Build and contribute

Use stable Rust with the x86_64 MSVC toolchain, Visual Studio C++ Build Tools
and the Windows SDK resource compiler.

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo build --locked --release
```

The executable is `target/release/laqay.exe`. These build commands do not
authorize a live clipboard or desktop test.

- [Development and diagnostics](docs/DEVELOPMENT.md) — architecture, preferences, clipboard formats and bounded probes.
- [Automated tests](docs/AUTOMATED_TESTS.md) — native/API suites and their limits.
- [Contributing](CONTRIBUTING.md) — changes, reports and review expectations.
- [Release procedure](docs/RELEASING.md) — versions, changelogs, tags and releases managed by release-plz.

## Project information

[Privacy and keyboard observation](docs/PRIVACY.md) explains how Ctrl+V is
recognized, when clipboard images are read, and what optional diagnostics expose.

[Report an issue](https://github.com/JAAvila-Of/laqay/issues/new/choose) ·
[Support](SUPPORT.md) · [Security](SECURITY.md) ·
[Governance](GOVERNANCE.md) · [Code of conduct](CODE_OF_CONDUCT.md)

MIT licensed. See [LICENSE](LICENSE), [third-party notices](THIRD_PARTY_NOTICES.md)
and [project identity](TRADEMARKS.md). Do not publish private clipboard contents
or unredacted diagnostic logs in public reports.
