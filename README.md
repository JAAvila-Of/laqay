# Laqay

Paste it. Save it.

Laqay is a Windows utility under development. Its goal is to save clipboard
images as PNG files in the active Windows Explorer folder when you press Ctrl+V.

**Current status:** engineering validation. Running `laqay.exe` now starts the
native tray application and observes Ctrl+V. Tray controls and per-user
preferences are implemented. A bounded desktop trial confirmed the icon's
enabled/disabled states and Exit cleanup. A subsequent trial of the integrated
application saved a screenshot as a valid PNG without notices or sounds.
A follow-up confirmed that disabling prevents image creation and re-enabling
restores it without disturbances. A same-session duplicate-launch trial confirmed
that the second copy exits without starting another observer. CI also validates
normal-mode preference round trips with the actual application in its isolated
VM. Execution at login and broader Explorer regressions still need testing.

Repeatable native/API validation is automated; see the
[test suites and coverage limits](docs/AUTOMATED_TESTS.md). Windows CI runs the
isolated clipboard suite and retains a validation log. These tests do not start
the application or inspect a person's clipboard.
Earlier bounded local-console and RDP trials saved clipboard screenshots as
PNGs and preserved basic native paste behavior. Those results predate the
shared-engine refactor and do not validate the new tray application.

## Requirements

- Planned support: Windows 10 and Windows 11, x86_64.
- Development: stable Rust with the MSVC toolchain, Visual Studio C++ Build Tools,
  and the Windows SDK resource compiler.
- The x86_64 MSVC build links the C runtime statically and requests no elevation.

## Build

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo build --locked --release
```

The Windows executable is `target/release/laqay.exe`. The executable uses the
Windows GUI subsystem. The diagnostic example uses a console for explicit output.
The build embeds enabled/disabled icons and a per-monitor DPI-aware manifest.
The manifest version comes from Cargo package metadata, managed by release-plz.

## Tray application

Launch `laqay.exe`, capture an image, focus a physical Explorer folder, and press
Ctrl+V. The notification icon has three menu items: **Enabled**, **Start with
Windows**, and **Exit**. The icon becomes gray while disabled. No additional
paste shortcut is required. The passive hook always forwards the original key.

Enabled defaults to on. Toggling it saves `HKCU\Software\Laqay\Enabled` and
invalidates queued requests. Disabling removes the hook on its dedicated input
thread; enabling installs it again. A publication already past its final check
may finish while the setting changes. UI and registry work run on another thread.

Automatic startup defaults to off. An explicit menu action adds or removes only
the `Laqay` value in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, with
the executable's full path quoted. Launching the application does not write
preferences. If you move the portable executable, turn startup off and on again
to update its registered path. Windows can separately disable startup entries.

There is one instance per interactive session, shared with the diagnostic paste
experiments. Exit removes the icon and stops input handling. Shutdown waits
briefly for the paste worker; a blocked external provider can cause the process
to terminate before staging-file cleanup, leaving a `.tmp` file. Completed PNGs
are published only after encoding and synchronization.

For an agreed, bounded desktop test, build with
`cargo build --locked --release --bins --examples`, then run:

```powershell
./scripts/Invoke-PasteProbe.ps1 -Tray -Seconds 30 -Destination <approved-folder> -OutputDirectory <private-log-directory>
```

This starts the actual tray application with a dedicated hook for at most 30
seconds, restricted to the approved folder. Enabled changes apply only to that
trial; Start with Windows is unavailable. Trial mode never reads or writes
registry preferences. The runner verifies process exit and terminates only its
own process if it exceeds the five-second shutdown grace period. Neither normal
mode nor trial mode should be launched as an unattended build check.

Add `-CheckSecondInstance` to a tray trial lasting at least ten seconds to launch
a second copy after the first is ready. The runner requires the duplicate to
exit successfully within three seconds without engine output while the first
remains active. It retains and cleans up both owned process handles.

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
native focus, the semantic control is a list, item, or verified static text
inside the native folder list, and both forms of focus
and the foreground window remain stable across the observations. Unknown,
editable, virtual, ambiguous, or unstable contexts produce no candidate.
This is a diagnostic policy, not proof that suppressing input is safe. Native
and semantic observations are not an atomic transaction. Basic local trials
covered rename, address/search fields, and two-tab selection. Rapid context
changes, virtual folders, and broader desktop regressions remain pending.

An RDP image-paste trial reached a stable folder view but was declined because
its focused element was Text inside the native List. The updated policy checks
up to 32 raw UIA ancestors for static Text, requiring the exact native list root
and no writable Value patterns, unknown controls, or disabled elements along the path.
If Value is available, `CurrentIsReadOnly` must confirm read-only access; query
failures decline. No control values are read or written. A successful follow-up
trial confirmed read-only Value on both the focused Text and its exact native
List ancestor. The path is checked before and after Shell inspection and again
before publishing. Editable fields remain excluded by policy; their desktop
regression matrix is still pending.

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
The shared paste engine connects native PNG encoding to this module.

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
confirmed reception in an RDP trial. A subsequent image-paste trial on Windows
11 25H2 (build 26200.9711) saved two 613x572 RGBA PNGs in the approved folder,
one per Ctrl+V, and exited cleanly. The tester confirmed correct images and no
notices or sounds. Observed receipt-to-save times were 180 ms and 72 ms; two
samples are not a performance benchmark. This covers a screenshot captured
inside that RDP session, not client clipboard redirection or the full matrix.

A later local-console trial (session protocol 0) saved two valid 1120x624 RGBA
PNGs, one per Ctrl+V. The tester confirmed correct images without notices or
sounds, and hook removal and process exit were verified. Observed times were
216 ms and 65 ms. A separate local trial preserved native paste of one regular
file: the destination matched the source SHA-256, no PNG was created, and the
tester reported normal behavior. Another local trial preserved text paste in
Notepad and Explorer's address bar: both image-handling requests were declined,
the approved folder remained empty, and the tester confirmed correct text
without unexpected notices or sounds. Text paste in a rename field was also
preserved and cancelled with Esc; the original name and file hash remained
unchanged. An isolated search-field trial also preserved text paste, identified
the stable Edit control outside the folder view, and created no files; the
tester confirmed correct text without disturbances.

A first two-tab trial saved one valid PNG in the approved first folder and
declined the paste after switching to the other folder, leaving it empty.
The tester confirmed two tabs in one Explorer window and a correct image
without disturbances. The reverse trial also passed: with only the second
folder approved, it saved a valid 1103x642 RGBA PNG there and declined the
first folder, whose original file and SHA-256 remained unchanged. The tester
confirmed the new image without disturbances; hook removal and process exit
were verified for both blocks. These trials used deliberate tab switches,
not rapid changes during encoding or publication.

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

The application operates offline, with no accounts, telemetry, clipboard
history, or keyboard history. Clipboard inspection is limited to paste
requests. Normal mode does not emit diagnostic logs. Bounded diagnostic modes
can log structural context and destination paths, but never clipboard contents.
Automatic startup is disabled by default.

## Releases

release-plz manages versions, changelogs, tags, and GitHub releases in git-only
mode. The Release workflow is manually dispatched during initial validation.
Use `prepare` to open a release PR. After reviewing and merging it, use `publish`
to publish the version. Only commits associated with release PRs are released.
A Windows job builds release assets from its tagged commit. Release PRs
must be reviewed before merging. No release is a claim of completed integration
validation; see [the test matrix](docs/integration-tests.md).

## License

MIT. See [LICENSE](LICENSE), [third-party notices](THIRD_PARTY_NOTICES.md), and
[project identity](TRADEMARKS.md). Release archives carry the executable and
license texts; an Actions artifact remains a development build.

## Community

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR. Use the
[issue forms](https://github.com/JAAvila-Of/laqay/issues/new/choose) for bugs,
questions, and proposals. Do not publish private clipboard contents or unredacted
diagnostics. Report vulnerabilities through the private channel in
[SECURITY.md](SECURITY.md).

[Governance](GOVERNANCE.md), [conduct](CODE_OF_CONDUCT.md),
[support](SUPPORT.md), and the [release procedure](docs/RELEASING.md) describe
how the project is maintained.
