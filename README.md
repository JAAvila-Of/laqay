# Laqay

Paste it. Save it.

Laqay is a Windows utility under development. Its goal is to save clipboard
images as PNG files in the active Windows Explorer folder when you press Ctrl+V.

**Current status:** engineering validation. Running `laqay.exe` currently exits
without registering input or changing system settings. An opt-in image-paste
experiment is implemented separately; its desktop behavior is not verified yet.
Tray controls and startup integration are not implemented.

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
The bounded experiment below connects native PNG encoding to this module.

## Bounded Ctrl+V experiment

Build with `cargo build --locked --release --examples`. After agreeing on a
desktop test window, run `scripts/Invoke-PasteProbe.ps1 -Seconds 30
-Destination <approved-folder> -OutputDirectory <private-log-directory>` from PowerShell. This runtime test
observes real keyboard input and can save a clipboard image; do not run it as
an unattended build check. It requires no UI automation helper.

The experiment creates a hidden message-only window and registers keyboard Raw
Input without suppressing legacy input. It never registers Ctrl+V as a global
hotkey or simulates a paste. Modifier state is ephemeral and unrelated keys are
not retained or logged. There is one instance per interactive session.

The first desktop trial produced no paste requests despite a confirmed Ctrl+V.
A later input-only trial in an active RDP session detected two Ctrl+V presses
through both Raw Input and the passive hook, with eight keyboard events per
source and no raw parsing errors. This verifies reception in that trial, not
complete image pasting or the cause of earlier missing events.
Aggregate counters now distinguish raw
message receipt, parsing, chord recognition, missing context, and queue rejection.
Pass `-InputBackend hook` to compare Raw Input with an optional passive
`WH_KEYBOARD_LL` observer. The hook always calls `CallNextHookEx`; it neither
blocks nor synthesizes input. In this mode both sources count events, but only
the hook submits paste requests, avoiding duplicate writes. The hook is removed
before shutdown. No event history, text, or clipboard contents enter these logs.
Context rejection diagnostics include structural focus metadata and view counts.

To isolate input reception from clipboard and folder handling, use
`scripts/Invoke-PasteProbe.ps1 -InputOnly -Seconds 30
-OutputDirectory <private-log-directory>`. No destination or screenshot is
needed. This mode counts both observers, has no paste worker, and does not query
clipboard data, clipboard sequence, or Explorer context. Native Ctrl+V continues
to reach the focused application. It still observes live keyboard input and
requires an agreed desktop test window.

The observer logs its own process/session IDs, station, thread/input desktop
names, whether its desktop receives input, and the session protocol before
registration and after cleanup. Metadata failures are explicit. It never
switches desktops or sessions. Readiness is announced from the message loop;
the runner relays it and fails if readiness is absent after five seconds.
Callback entry is counted independently of thread-local state. These diagnostics
confirmed reception in one RDP trial; complete image pasting over RDP is not
validated yet.

For a Ctrl+V request it checks the Explorer process, native and semantic focus,
the physical Shell folder, and clipboard sequence. Only the explicitly approved
destination directory is eligible; other folders are declined before clipboard
data is read. File transfers, virtual
files, text, unsupported formats, uncertain context, and additional modifiers
are declined. PNG, uncompressed 24/32-bit DIB, and supported DIBV5 data are
converted using WIC. Existing PNG bytes are preserved after validation, with
allocation padding after IEND removed. Images and decoded buffers are capped
at 128 MiB. Palettes, compressed DIB, unusual bit masks, and embedded DIB color
profiles are currently rejected; CF_BITMAP-only content is not supported yet.

Before publishing the PNG it rechecks context and clipboard sequence. Those
checks are not an atomic Windows transaction: context can still change between
the final check and file publication. A busy bounded request queue can decline
rapid requests. Explorer also receives the original Ctrl+V; whether it produces
a sound, notice, or another operation must be measured in the desktop test.
No clipboard contents are replaced or copied to the logs.

The observer requests shutdown after 30 seconds at most. The PowerShell runner
terminates only its own process if it exceeds an additional five-second grace
period and checks that it exited. All image files are staged and published in
the selected Explorer folder, never in the private log directory automatically.

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
