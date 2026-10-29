# Laqay

Paste it. Save it.

Laqay is a Windows utility under development. Its goal is to save clipboard
images as PNG files in the active Windows Explorer folder when you press Ctrl+V.

**Current status:** initial engineering validation. Image paste, tray controls,
and startup integration are not implemented. Running `laqay.exe` currently exits
without installing hooks or changing system settings.

## Requirements

- Planned support: Windows 10 and Windows 11, x86_64.
- Development: stable Rust with the MSVC toolchain and Visual Studio C++ Build Tools.
- No administrator privileges or external application runtime are intended.

## Build

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo build --locked --release
```

The Windows executable is `target/release/laqay.exe`. The executable uses the
Windows GUI subsystem. The diagnostic example uses a console for explicit output.

## Explorer diagnostic

```sh
cargo run --locked --example explorer_probe -- 5
```

Focus an Explorer folder during the five-second delay. The diagnostic takes one
snapshot of the foreground window, focus, and Shell views. It uses `IShellWindows`,
`IServiceProvider`, `IShellBrowser::QueryActiveShellView`, and `IFolderView` to
inspect filesystem paths. A separate, windowless MTA thread uses UI Automation
to classify the focused control and compare it before and after Shell inspection.
It does not install a hook, suppress input, read the
clipboard, or create images. Output can contain the selected folder path.

The diagnostic reports a directory only when a single filesystem view contains
native focus, the semantic control is a list or item, and both forms of focus
and the foreground window remain stable across the observations. Unknown,
editable, virtual, ambiguous, or unstable contexts produce no candidate.
This is a diagnostic policy, not proof that suppressing input is safe. Native
and semantic observations are not an atomic transaction. Desktop validation of
rename fields, search, tabs, and context changes is still pending for this policy.

For coordinated desktop testing, run `explorer_probe --wait` instead of a delay.
It announces readiness and waits for one line on stdin before taking a snapshot.
EOF cancels the snapshot. This allows a test runner to finish build scheduling
before a short foreground interaction begins.

Runners without interactive stdin can use `explorer_probe --event <unique-id>`.
Wait for its readiness message, then signal the named Windows event
`Local\Laqay.ExplorerProbe.<unique-id>`. The identifier accepts 1-64 ASCII letters,
digits, or hyphens. The one-shot wait expires after 180 seconds and never polls.
Use a fresh identifier for each invocation.

`explorer_probe --inspect <native-window-handle>` inspects structural control
metadata without activating a window. Handles can become invalid between
observations. This mode requests no accessible names, text values, or clipboard
contents and does not authorize a paste target.

## File publication foundation

The library can stage encoder output in a uniquely reserved `.tmp` file inside
the destination folder and publish it with a non-replacing move after encoding
and synchronization complete. Filename collisions, including simultaneous
writers, use increasing suffixes. Encoding failure removes the staging file
when possible; a disconnected or changed destination can leave a `.tmp` file.
PNG encoding and the paste workflow are not connected to this module yet.

## Intended behavior

Capture an image, open a filesystem folder, and press Ctrl+V. Laqay should write
`Screenshot_YYYYMMDD_HHMMSS.png`, preserving dimensions and available alpha.
Filename collisions must never overwrite existing files. Ordinary file and text
pasting must retain native behavior. Ambiguous contexts must retain native paste.

Planned image representations are PNG, DIBV5, DIB, and bitmap, in that order.
Copied files and virtual Shell files take priority over image conversion.

## Privacy

The application will operate offline, with no accounts, telemetry, clipboard
history, or keyboard history. Clipboard inspection will be limited to paste
requests. Automatic startup will be disabled by default.

## Releases

release-plz manages versions, changelogs, tags, and GitHub releases in git-only
mode. The Release workflow is manually dispatched during initial validation.
Use `prepare` to open a release PR. After reviewing and merging it, use `publish`
to publish the version. Only commits associated with release PRs are released.
A Windows job builds release assets from its tagged commit. Release PRs
must be reviewed before merging. No release is a claim of completed integration
validation; see [the test matrix](docs/integration-tests.md).

## License

MIT. See [LICENSE](LICENSE).
