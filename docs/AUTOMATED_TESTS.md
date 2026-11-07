# Automated Windows validation

The component suites exercise production policy, native registry operations,
image codecs, and file publication without starting Laqay or installing an
input observer. They do not require a tester to click the tray or paste data.
An additional CI-only application check launches the normal executable in the
ephemeral Windows VM and controls only its owned windows through native commands.

## Regular suite

```sh
cargo test --locked
```

Registry tests create uniquely named keys under `HKCU\Software\LaqayTest.*`.
The production settings operations use that owned root during tests; application
entry points always use HKCU normally. Tests never write the user's real Laqay
preference or effective Run entry. Successful tests verify key deletion, with
additional cleanup during unwinding.

A separate child process reopens the saved settings and verifies both Enabled
states and startup registration. The parent checks its exit status and verifies
that the exact child case ran. Children have no console windows and are bounded
by a 30-second watchdog that owns only the spawned process.

## Isolated native clipboard suite

```sh
cargo test --locked --all-features
```

The `isolated-clipboard-tests` feature adds a matrix using the real Windows
clipboard API in a dedicated child process. It creates an exclusively owned,
noninteractive window station and desktop, verifies their isolation, and uses
synthetic fixtures. No visible window, input hook, key simulation, or desktop
activation is involved. The interactive clipboard is never a fallback.

The regular suite creates small synthetic 16/24/32-bit DIB sections in memory
and checks HBITMAP conversion, orientation, opaque alpha, metadata limits, and
borrowed-handle ownership. It never obtains a screen DC. The isolated suite
also transfers a genuine CF_BITMAP to its private clipboard, exercises its
native copy path directly (Windows can synthesize higher-priority DIB formats),
and verifies PNG/file priority and snapshot validity after clearing the source.
It checks that bitmap sources bypass synthesized DIB conversion without changing
colors, while an earlier DIB source keeps priority over a later bitmap.

Creating a uniquely named station requires Windows station-creation permissions.
An account without them will get a failing capability check before any clipboard
access; do not elevate a personal session just to run this suite. The mandatory
Windows CI job and release validation run all features on an ephemeral hosted
VM with the required permissions. See [Windows station isolation](https://learn.microsoft.com/en-us/windows/win32/winstation/window-stations)
and [hosted runner privileges](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#administrative-privileges).

Child entry points appear as `ignored` during flat test discovery. Their
parent tests explicitly execute them with `--exact --ignored` in fresh processes
and require a successful result containing one executed test. They are not
optional coverage in the all-features CI run.

The private clipboard child also couples real DIB snapshots, WIC encoding and
native file publication to the runtime's production request-matching predicate.
It checks an unchanged control through a filename collision, a real sequence
change before encoding, a real sequence change after staging/before publication,
and a generation revoked by disabling/re-enabling during encoding. Each revoked
case must preserve the existing file, remove only staging, and permit a fresh
snapshot to recover without overwrite. Window/focus values in this component
fixture are fixed synthetic fields; it does not drive Explorer, a physical key,
or a desktop focus race. The parent requires all four stage markers and retains
the child output in CI.

## Isolated real Shell view

The `isolated-shell-tests` feature hosts the Windows `IExplorerBrowser` and
`IFolderView` implementations in hidden owned windows on a newly created,
nonvisible window station. It uses the same station isolation as the clipboard
suite, in a separate child with a 30-second watchdog. Station creation failure
fails the test before COM or window creation; there is no interactive fallback.
Regular `cargo test --locked` does not enable this capability.

The real writer supplies a completed staging file and its pinned identity.
The production Shell-item lookup must accept that singleton only with its lease,
reject an unpinned singleton and a same-name/same-bytes copy in another folder,
and reject a view containing an additional foreign file. Successful publication
encodes once; rejection removes only the owned staging file and preserves the
foreign file. Each view must report the expected filesystem path and item count;
navigation success alone is insufficient. The fixture explicitly refreshes only
its own hidden view after filesystem mutations, rather than requiring interactive
Shell notifications on its private station. This is test preparation, not a
production refresh or focus repair. View state and travel history are not
persisted. The CI validation log retains the successful child output.

This exercises real PIDL/path resolution and staging exclusion, without input,
clipboard access, foreground changes, or opening the Explorer application.
It does not reproduce a UIA identity transition, drive Ctrl+V, or prove the cause
of an intermittent RDP failure. See Microsoft's
[ExplorerBrowser contract](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-iexplorerbrowser)
and [browser options](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ne-shobjidl_core-explorer_browser_options).

## Hosted storage capacity check

An explicit CI step runs `scripts/Test-StorageFailure.ps1` on a disposable
GitHub-hosted Windows runner. It creates a bounded 64 MiB NTFS scratch VHD,
executes the real disk-full writer/recovery test, validates its native evidence
and detaches/removes the fixture. Its environment guard refuses local and
self-hosted execution before disk operations. Normal Cargo commands above
leave this additional fixture-dependent test ignored and do not mount disks.
The `laqay-storage-validation` artifact retains its report and logs, including
on failure. See the [storage acceptance and limits](integration-tests.md#isolated-storage-capacity-regression).

## Coverage and limits

The explicit hosted share step uses `scripts/Test-ShareFailure.ps1` for a
separate fixture-dependent ignored test. It withdraws only its own loopback SMB
share between complete staging and publication, then checks fresh-image
recovery. Normal Cargo commands do not create shares. Local/self-hosted
execution is refused. The `laqay-share-validation` artifact records native
outcome, residue and controller cleanup separately; see the
[withdrawal scope](integration-tests.md#isolated-smb-withdrawal-regression).

The normal-mode application check uses `Invoke-PreferencesProbe.ps1 -Automated`
for Enabled and Startup. That mode requires a GitHub-hosted runner and refuses
local or self-hosted execution. It
sends standard WM_COMMAND messages to its owned Laqay window, using the same
action handlers as the tray menu; it never clicks, types, or activates a window.
Enabled is changed, the application exits and restarts, and another toggle must
restore the initial state, proving that the restarted application loaded it.
Startup must add the exact quoted executable and remove it again. Original
values are restored and owned process exits are checked. Reports and backups
are retained as the `laqay-preference-validation` artifact, including on failure.

This tests the application/controller path and real account settings inside the
CI VM. It does not inspect the menu's visual rendering or execute the program
through Windows login. The working computer's settings remain separate.

The same CI-only runner also checks `SessionEnd` against the normal executable.
It sends `WM_QUERYENDSESSION` and cancelled `WM_ENDSESSION` notifications for
both shutdown and logoff flags only to its owned Laqay tray window. Each query
must allow termination, while cancellation must retain the same process/window
and unchanged preferences. A confirmed notification must then close that exact
process with exit code zero within five seconds. Registry values are restored
and process cleanup is checked by the existing probe. Reports are retained in
`laqay-preference-validation`.

This never calls a Windows logoff/shutdown API, broadcasts a message, sends input,
or activates a window. Six inert tests exercise the actual hosted/explicit-mode
guards; local or self-hosted automated execution is refused. It tests application
notification handling while idle, not an actual OS shutdown, a blocked provider,
or every encoding/publication stage. The separate guest lifecycle test covers
Exit while a clipboard read is independently proven blocked.
The notification sequence follows the Windows
[query](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-queryendsession)
and [completion](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-endsession)
contracts.

| Area | Automated evidence |
| --- | --- |
| Preferences | Defaults without creating keys, DWORD persistence across processes, Unicode/path quoting, startup add/remove, preserving other entries, malformed/empty/oversized values, error propagation; application-level round trips in the CI VM |
| Clipboard | Empty/text rejection, PNG priority and preservation, native DIB and HBITMAP retrieval, regular/virtual file priority, stale sequences, locked clipboard and recovery |
| Images | Dimensions, channels, orientation, V5 alpha, opaque HBITMAP snapshots and ownership, malformed metadata/chunks, every truncated input prefix, allocation bounds, PNG padding removal |
| Files | Collision preservation, concurrent writers, invalid destinations, failed encoding cleanup, cancellation during staging and collision retries even after re-enabling; real disk-full failure and recovery on the bounded hosted CI volume |
| Context and keys | Ambiguous/editable/virtual-context rejection, focus stability, modifier handling, key repeat, cancellation generations |
| Public tooling | Conventional subjects, policy files/links, dependency license collection, missing-notice failures; portable archive content, AMD64 GUI header and checksums, with malformed-package rejection and the actual packaging command |

The Windows CI artifact `laqay-validation-log` retains the test output, including
on failure. Dependency/security and public-policy jobs remain required checks.

These are component, controller, and native-API integration results. They do not
prove real
Explorer focus/tab behavior, a physical keyboard gesture, RDP clipboard
redirection, the tray's visual state, execution at login, Windows 10 desktop
compatibility, writable UNC/OneDrive behavior, or disconnected-share/physical-device failure. Those
remain separate scenarios in the [integration matrix](integration-tests.md).
An automated Run-value round trip does not log out or restart Windows.

Desktop scenarios must run in a suitable isolated Windows session, with any
control of a person's working desktop agreed beforehand. Do not mark them as
passed based on component tests or launch a live observer as part of Cargo test.
