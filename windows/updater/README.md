# Windows updater boundary and acceptance

## Identity and destination

Only the running `silique.exe` can establish its own installed identity. The
64-bit HKLM uninstall registration for the fixed Inno AppId must match its exact
canonical directory, quoted uninstaller path and actual executable version.
The opened module is also compared with the process's loaded image mapping.
Every path component is opened without following reparse points; hardlinks,
short-name/final-path aliases and missing/stale registrations fail closed.
HKCU, portable siblings and legacy user-profile installations are manual-only.

Default **and protected custom** machine destinations are supported. Placement
under Program Files alone is not authority. Directory ancestors and the module,
uninstaller and guard require a conservative administrator-managed owner/DACL:
only SYSTEM, Administrators or TrustedInstaller can hold mutation rights.
Unrecognized/conditional ACLs are manual-only. Inno receives `/DIR` explicitly,
rechecks the HKLM registration and retains that directory, never defaulting to a
second installation despite `UsePreviousAppDir=no`.

## Locks and process protocol

1. The runner acquires the global AppId application mutex **before Flutter or
   notebook/credential initialization**. An existing update gate blocks startup.
2. Native install serializes calls, requires a newer build, validates PE version,
   and hashes the signed expected size/SHA256 against an opened EXE. File handles
   allow read sharing only. Every ancestor uses `FILE_LIST_DIRECTORY` (not just
   attributes), read sharing only and no reparse traversal. This rejects
   pre-existing write/delete handles as well as later mutation/namespace opens.
   A retained read-only image section and second hash additionally guard against
   writable mappings whose original file handle was already closed.
   These consumption-lifetime pins cover the downloaded EXE and copied guard.
   The separately verified, administrator-only destination tree is pinned only
   by the original app through verification/UAC. Those pins are not inherited:
   they must close before the guard ACK permits Inno to rename destination files.
3. The installation-wide update mutex fences new supported application instances.
   A process snapshot rejects existing legacy instances of this same module;
   unverifiable same-name processes cause a conservative refusal. No process is
   forcibly closed. Manual Inno runs acquire the same gate atomically and hold it
   for their entire main-process lifetime. Inno's SetupMutex prevents concurrent
   installers, and AppMutex refuses replacement while a participating app lives.
4. A pinned copy of the installed, protected, statically linked **asInvoker**
   `silique_update_guard.exe` receives only an explicit inherited handle list.
   Before starting that copy, native code also retains its read-only
   `SEC_IMAGE_NO_EXECUTE` section and rehashes it against the protected original;
   failure to establish the section is fatal, including for a pre-existing copy.
   It cannot launch anything. Its READY event is observed **before** requesting
   ordinary `runas` UAC. Inherited file/ancestor/image-section/gate handles survive
   the original application's exit.
5. The random first-instance local pipe accepts a high-integrity client only.
   Identification-level SQOS permits integrity inspection, not acting as admin.
   Wire sequence is `0x53`, then a **4-byte DWORD remote handle value**, then ACK
   `0x41`. The elevated Inno main process duplicates its own process handle into
   the guard with only `SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION` and sends
   that value. The guard verifies its PID against the actual pipe client. This
   avoids requiring a standard user to open an over-the-shoulder administrator's
   process. The shipped builder requires **32-bit Inno Setup 6**; WinAPI external
   declarations in the script use its 32-bit handle ABI.
6. ACK is withheld until the original app process exits. Inno joins in
   `InitializeSetup`, before any replacement, and the guard retains artifact,
   ancestor, image-section and update-gate locks
   until that authenticated **main process exits**, not pipe disconnect, an ACK,
   ShellExecute's bootstrap process, a timer or the original app exiting.
7. Only a failed ShellExecute call permits pre-launch guard cancellation and a
   `cancelled`/`failed` result. Once ShellExecute succeeds, return `launched` even
   with a missing bootstrap handle. Launch is not completed installation. Unknown
   post-launch lifetime or failed authentication retains locks indefinitely,
   deliberately failing closed; it can require logoff/reboot to clear an orphan
   gate. Never resume editing on an invented post-launch failure.

Setup never launches the notebook with its elevated token. The user reopens it
from the normal shortcut. The installer remains unsigned: unknown-publisher UAC
is expected, not bypassed. The boundary does not defend against administrators,
SYSTEM or same-account arbitrary process termination/debugging. An uncooperative
old executable launched after the legacy-process snapshot cannot honor the new
mutex protocol; Inno must still never force-close it (file-in-use failure is
preferable). This is not an unsaved-data handoff for arbitrary historical apps.

## Tests and evidence

`tool/build_windows.ps1` builds the production targets and both native test
executables, then invokes `tool/windows/test_updater_acceptance.ps1` on a clean,
elevated, disposable native Windows runner. The script refuses existing AppId
registrations/installations and owner machines. The weak ancestor-lock negative
control must fail with exit 86 before the identical production barrier test may
pass. There is no force-killed-window smoke accepted as updater evidence.

Acceptance covers real ownership/registry views, stale records/uninstaller,
portable/sibling/junction/hardlink rejection, protected custom-directory update,
user-writable ACL rejection, Unicode/spaces, pre-open writers/deleters, overwrite/
rename/delete barriers, writable mappings, cancellation release, legacy second
process refusal, independent guard lifetime and a real test-only Inno barrier
across parent exit/consumption. Its completion event and pause hook are compiled
only with `NativeAcceptance`, never distributed. It checks installed bundle bytes
and synthetic external data/identifiers; this is **not a real SQLite upgrade or
credential-store test**. Dart/native storage acceptance remains separately
required.

Focused local checks can compile with MinGW `-std=c++17 -Wall -Wextra -Werror
-DNOMINMAX -municode -static` and run `--identity-path-tests`, `--barrier-tests`
and `--guard-tests GUARD_EXE` under Wine. These explicitly do **not** replace
native Windows acceptance. The full test intentionally fails if reparse support
is missing, rather than skipping its safety assertions. Interactive UAC,
over-the-shoulder UAC, real owner notebooks and owner-device behavior require
separate native/manual verification; an already-elevated CI transport proves none
of those.
