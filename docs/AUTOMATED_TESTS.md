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

Creating a uniquely named station requires Windows station-creation permissions.
An account without them will get a failing capability check before any clipboard
access; do not elevate a personal session just to run this suite. The mandatory
Windows CI job and release validation run all features on an ephemeral hosted
VM with the required permissions. See [Windows station isolation](https://learn.microsoft.com/en-us/windows/win32/winstation/window-stations)
and [hosted runner privileges](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#administrative-privileges).

Two child entry points appear as `ignored` during flat test discovery. Their
parent tests explicitly execute them with `--exact --ignored` in fresh processes
and require a successful result containing one executed test. They are not
optional coverage in the all-features CI run.

## Coverage and limits

The normal-mode application check uses `Invoke-PreferencesProbe.ps1 -Automated`
for Enabled and Startup. That mode refuses to run outside GitHub Actions. It
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

| Area | Automated evidence |
| --- | --- |
| Preferences | Defaults without creating keys, DWORD persistence across processes, Unicode/path quoting, startup add/remove, preserving other entries, malformed/empty/oversized values, error propagation; application-level round trips in the CI VM |
| Clipboard | Empty/text rejection, PNG priority and preservation, native DIB retrieval, regular/virtual file priority, stale sequences, locked clipboard and recovery |
| Images | Dimensions, channels, orientation, V5 alpha, malformed metadata/chunks, every truncated input prefix, allocation bounds, PNG padding removal |
| Files | Collision preservation, concurrent writers, invalid destinations, failed encoding cleanup, cancellation during staging even after re-enabling |
| Context and keys | Ambiguous/editable/virtual-context rejection, focus stability, modifier handling, key repeat, cancellation generations |
| Public tooling | Conventional subjects, policy files/links, dependency license collection, missing-notice failures |

The Windows CI artifact `laqay-validation-log` retains the test output, including
on failure. Dependency/security and public-policy jobs remain required checks.

These are component and native-API integration results. They do not prove real
Explorer focus/tab behavior, a physical keyboard gesture, RDP clipboard
redirection, the tray's visual state, execution at login, Windows 10 desktop
compatibility, writable UNC/OneDrive behavior, or real disk/share failure. Those
remain separate scenarios in the [integration matrix](integration-tests.md).
An automated Run-value round trip does not log out or restart Windows.

Desktop scenarios must run in a suitable isolated Windows session, with any
control of a person's working desktop agreed beforehand. Do not mark them as
passed based on component tests or launch a live observer as part of Cargo test.
