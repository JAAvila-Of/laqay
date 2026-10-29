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
inspect filesystem paths. It does not install a hook, suppress input, read the
clipboard, or create images. Output can contain the selected folder path.

Visible views and focused descendants are observations, not proof of a safe
paste target. Rename fields and Windows 11 tabs require additional validation.

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
