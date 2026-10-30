# Windows integration validation

This matrix has not been completed. One authorized RDP image-paste trial on
Windows 11 25H2 (build 26200.9711) passed the basic T33/T35 path: two Ctrl+V
presses created two valid 613x572 RGBA PNGs in the approved folder. The tester
confirmed correct images without notices or sounds. The initial folder was
empty; its focused Text and exact native List ancestor both exposed read-only
Value. The hook was removed and process exit was verified. This result is
limited to that session and screenshot, not a pass for other matrix scenarios.
A subsequent local-console trial (protocol 0) passed the basic T17/T33 path:
two presses saved two valid 1120x624 RGBA PNGs. The tester confirmed correct
images without notices or sounds; hook removal and process exit were verified.
A local T04 trial also passed for one regular file: native paste preserved its
SHA-256, created no PNG, and produced no unexpected notices or sounds according
to the tester. A local T07/T12 trial preserved text in Notepad and Explorer's
address bar; the observer declined both contexts, created no files, and the
tester confirmed correct text without disturbances. A basic local T14 trial
also preserved text paste in a rename Edit control; Esc cancelled the edit,
the original name/hash remained unchanged, and no PNG was created. The search
part of that trial used an incorrect shortcut and did not validate T13. A
separate T13 trial using Ctrl+F identified the search Edit control outside the
folder view and declined before image access; no files were created, and the
tester confirmed normal text paste. A first T16 two-tab trial saved a valid
PNG only in the approved first folder and explicitly declined the other
folder; the tester confirmed both tabs were in one window. The reverse block
also passed: a valid PNG appeared only in the newly approved second folder,
the first folder's original file/hash stayed unchanged, and the tester reported
no disturbances. This covers deliberate two-tab selection in both directions,
not rapid changes during a paste. Multiple/virtual files, other destinations,
and the remaining matrix are still pending.
These results predate the shared-engine and tray integration. The entry point
now starts the real tray application. A bounded local-console tray trial passed
the basic T28 exit path: the tester toggled Enabled off and on, confirmed the
icon changed blue/gray/blue, and selected Exit. Start with Windows was unavailable
as required in trial mode. Hook removal and process exit were verified, with
no runtime errors or watchdog termination. No paste was attempted, so T25's
native-paste behavior remains unverified. Actual startup preferences, Explorer
restart recovery, shared single-instance behavior, shutdown with pending work,
and regression testing of earlier paste results remain pending.
Unit tests cover generation cancellation and
preference/command parsing; they do not exercise the real tray or registry.

Use `Invoke-PasteProbe.ps1 -Tray` for a separately agreed, 30-second maximum
trial restricted to one approved folder. Trial Enabled changes are temporary,
Start with Windows is unavailable, and preferences are never read or written.
Actual preference persistence and login startup require separate normal-mode
validation. Check icon disappearance and owned process exit after every block.
Run the matrix on Windows 10 and Windows 11 and record the OS build and results.

| ID | Scenario | Required result |
| --- | --- | --- |
| T01 | Region screenshot | PNG in active folder |
| T02 | Full-screen screenshot | PNG in active folder |
| T03 | PNG with alpha | Exact dimensions and alpha preserved |
| T04 | Regular copied file | Native paste |
| T05 | Multiple copied files | Native paste |
| T06 | Text clipboard | Native behavior |
| T07 | Notepad | Native paste |
| T08 | VS Code | Native paste |
| T09 | Rider | Native paste |
| T10 | Windows Terminal | Native paste |
| T11 | Browser | Native paste |
| T12 | Explorer address bar | Native paste |
| T13 | Explorer search | Native paste |
| T14 | Rename field | Native paste |
| T15 | Multiple Explorer windows | Correct foreground folder |
| T16 | Windows 11 tabs | Active tab or safe rejection |
| T17 | Local directory | PNG created |
| T18 | Writable UNC directory | PNG created |
| T19 | Read-only directory | Safe failure, no incomplete file |
| T20 | Virtual folder | Native behavior |
| T21 | Rapid paste and key repeat | No overwrite or unintended duplicates |
| T22 | Empty clipboard | Native behavior |
| T23 | Locked clipboard | Safe failure |
| T24 | Large image | No UI freeze |
| T25 | Disabled | Native behavior |
| T26 | Second instance | No duplicate hook |
| T27 | Startup preference | Starts on login only when enabled |
| T28 | Tray exit | Clean resource teardown |
| T29 | Tab changes during paste | No write to unintended folder |
| T30 | Clipboard changes during paste | No stale image write |
| T31 | Virtual files with image formats | Native Shell transfer |
| T32 | Disk full or share disconnected | No incomplete output |
| T33 | Empty folder with focused static Text inside its native List | PNG created in that folder |
| T34 | Text inside an editor or outside the native folder List | Native behavior, no image file |
| T35 | Screenshot captured inside an RDP session | PNG created in the remote folder |
| T36 | Client screenshot shared through RDP clipboard | PNG when image data is available; safe rejection otherwise |

For the initial diagnostic, compare reported paths and focus against the real UI
with multiple tabs, address/search fields, rename controls, and virtual folders.
Never use a cached diagnostic snapshot to suppress a later key event.
