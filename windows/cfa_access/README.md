# Silique Windows controlled-folder-access helper

`silique_folder_access.exe` is a separate native x64/MSVC console executable next
to `silique.exe`. It uses a static CRT, an **asInvoker** manifest, and UTF-8 JSON
stdout. It does not load Flutter, Dart, application DLLs, application preferences,
or launch/relaunch the application. It is intentionally **unsigned**: an actual
UAC consent dialog shows **Unknown publisher**. This is not a signed/trusted
publisher claim.

## Public contract

```text
silique_folder_access.exe --inspect <existing-absolute-root>
silique_folder_access.exe --request <existing-absolute-root>
```

Exactly one JSON object is emitted, with `status`, `executable`, and `message`.
Status is `confirmed`, `unconfirmed`, `allowed`, `cancelled`, or `failed`.
`executable` is derived from the helper's own module directory plus the literal
`silique.exe`.
No root, event contents, PowerShell diagnostics, or arbitrary error text is copied
into messages. Public exit code is 0 for non-failure statuses and 1 for `failed`;
consumers must read JSON even when the process exits nonzero. No `canRequest`
field is currently emitted.

`--inspect` is read-only. It pins/validates the real helper, sibling application,
and root, then queries `Microsoft-Windows-Windows Defender/Operational` via the
native Windows Event Log API. Confirmation requires structured **1123**, exact
provider/channel, a real UTC FILETIME no older than 300 seconds (future times are
rejected), exact normalized `Process Name`, and `Path` equal to or inside root
with a component boundary. Localized message strings, generic I/O errors, and
CFA-enabled state are not evidence. Named XPath extraction avoids positional
EventData assumptions and rejects missing/array/duplicate or mistyped values.

`--request` independently repeats validation and fresh-evidence checks. It then
uses `ShellExecuteExW` with `runas` on the pinned **same helper**, with exactly the
constant argument `--apply`. No root, target, command, script path, or caller data
crosses that command-line boundary. Cancellation maps to `cancelled`; only a
controlled verified-success child exit code maps to `allowed` (ordinary exit 0,
a crash, unknown exit, or active child does not).

Internal `--apply` accepts **no additional arguments**, checks its own token is
elevated, derives/pins the sibling again, checks the protected bundle again, and
requires another fresh structured 1123 for that executable (any safely validated
root). It rechecks freshness immediately before executing the narrow operation.

## Protected-install guard

Diagnosis still works for legacy/per-user/portable copies. Automatic permission
changes do **not**: both request and elevated apply require a descendant bundle
of the native `FOLDERID_ProgramFiles`, obtained via the known-folder API, not an
environment variable. Refusal is `failed` with an explicit **protected Program
Files installation** message.

The guard checks final handle paths and every path component; refuses UNC,
remote/removable drives, reparse points, ambiguous aliases, and bundle hardlinks;
and pins all bundle files/directories without share-write or share-delete for
the duration of consent/operation. It recursively includes **all** files, not
just the EXEs: app.so, DLLs, assets and nested directories are covered. Ownership
must be SYSTEM, Builtin Administrators, or TrustedInstaller. Every effective
allow ACE granting any write/append/create-child/delete/delete-child/owner/DACL
change to any other trustee is refused, even when a deny ACE might counter it.
Unknown/object/callback ACEs, NULL DACLs, unreadable metadata, recursion >64, or
>12,000 pinned entries fail closed. Ancestors cannot grant replacement/reparse/
DACL rights; Program Files and its branch to the bundle also cannot grant
ordinary users create/write rights. These checks do not change ACLs.

This conservative allow-list ACL analysis may reject unusual but effectively
safe enterprise ACLs. That is deliberate; it must not guess that a writable
bundle is protected. An installer must create/admin-own the entire bundle under
Program Files; copying a user-owned tree there is not enough. The helper itself
does not migrate an installation or data.

## Narrow system PowerShell operation

Only the absolute native `GetSystemDirectoryW()` Windows PowerShell path is used,
with `-NoLogo -NoProfile -NonInteractive -EncodedCommand`. There is no shell,
profile, user PATH, user PSModulePath, download, script file in AppData/Temp,
execution-policy bypass, or arbitrary-command option. The child has a minimal
explicit environment, system-only module path, system working directory,
noninherited file pins, a restricted stdio handle list, no window, and a
kill-on-close job/60-second timeout. Module analysis cache is disabled with NUL.

Both `CimCmdlets.psd1` and `Defender.psd1` are imported by their explicit absolute
system manifest paths, with autoload disabled. Their trees and PowerShell's
executable/ancestors are verified read-only for trusted ownership/DACLs and no
reparse points before use. Protected **OS** hardlinks (WinSxS servicing) are
allowed only here, after the shared inode's protected descriptor is checked;
this exception does not apply to the application bundle.

Executable and manifest paths are UTF-16/base64 **data expressions**, not quoted
user text inserted into script source. Wildcards (`*`, `?`, `[`, `]`), environment
macros, invalid/control UTF-16, ADS, traversal, reserved DOS names and ambiguous
Win32 spellings are refused. Apostrophes, `$` and semicolons in an otherwise
valid filename are safe data, covered by the tests. The script performs only:

```powershell
Defender\Add-MpPreference -ControlledFolderAccessAllowedApplications @($target) -ErrorAction Stop
Defender\Get-MpPreference -ErrorAction Stop
```

Success requires a single valid preference object and an exact ordinal-
case-insensitive string entry equal to the self-derived full executable path.
Script exit **21** is the only success; wildcard validation failure, bad
readback, policy/update exception, unexpected exit and timeout fail closed.
No `Set-MpPreference`, exclusion changes, protection disablement, wildcard grant,
module install, generic command runner, or application-elevated launch exists.
Readback failure can follow a partially completed Add operation; `failed` means
**not verified**, not a promise that a partial change was rolled back.

## Path/evidence limits and threat model

Case comparison is ordinal, separators are normalized, and `%USERPROFILE%` is
expanded only as an initial complete component using the token's known profile
folder, not inherited environment text. NT device paths are mapped through
`QueryDosDeviceW` only when unambiguous; unresolved/unsupported namespace paths
fail closed. Short-name aliases,
SUBST aliases and reparse-based paths are rejected rather than guessed. Every
existing directory must also report zero `FileCaseSensitiveInfo` flags: WSL/
case-sensitive directories or unknown/unsupported case semantics are refused,
so ordinal-case-insensitive comparison cannot conflate distinct files/roots.
A blocked create may name a missing file: all existing ancestors are checked.

There is no claim of defense against an already compromised user/application,
malicious administrator, kernel compromise, UAC bypass, or post-approval changes
made by an administrator. Pinning alone is **not** durable installation
protection; protected ownership and ACLs are required. CFA grants the executable
application access, **not access restricted to the requested root**. The UI must
explain that scope and the unsigned UAC prompt before the user's consent.

## Build and safe verification

No Flutter SDK is needed for standalone native tests. From a Windows MSVC/CMake
shell (or use the Visual Studio bundled CMake absolute executable):

```text
cmake -S windows/cfa_access -B <isolated-build-dir> -G "Visual Studio 17 2022" -A x64
cmake --build <isolated-build-dir> --config Release
ctest --test-dir <isolated-build-dir> -C Release --output-on-failure -V
```

This builds both `Release/silique_folder_access.exe` and
`Release/silique_cfa_tests.exe`. Pure native tests exercise parsing, normalization,
path/event/time matching, ACL analysis, injection resistance, exact result
mapping, and consent/elevation/readback gates using an inert platform. Read-only
integration checks validate real paths, query the Event Log without generating
an event, and pin/validate the actual system dependency files. A PowerShell
**parser-only** test treats the encoded operation as AST input; it never invokes,
dot-sources, evaluates, or imports the operation. The operation cannot execute
through that test path. No dry-run setting mutation exists.

For real CLI smoke tests, put a real scratch copy of `silique.exe` alongside the
built helper, without launching the application, then use:

```text
python windows/cfa_access/verify_readonly.py <helper.exe> <existing-root>
```

The smoke script checks its live token is **not elevated before every call**.
It invokes only `--inspect`, unelevated `--apply` (must refuse), invalid extra
apply arguments, and read-only invalid-root inspections. It never invokes
`--request`, never raises UAC, and refuses to start any helper if elevated.
Inspecting a scratch sibling without a matching fresh event should be
`unconfirmed`, not a manufactured positive result.

The top-level Windows CMake builds/installs the helper next to the runner and
makes the runner depend on it. Test binaries are off by default in a Flutter
bundle. `tool/build_windows.ps1` requires the helper before packaging. An actual
consent/change/readback E2E requires a protected installed bundle, a real fresh
block for its exact executable, and separately authorized interactive testing.
It is intentionally **not** part of automated verification on the owner's live
system.

Reference API documentation: Microsoft Learn, `EvtCreateRenderContext`,
"Rendering Events", and MSVC `/DEPENDENTLOADFLAG`. The PE load-config flag 0x800
restricts static imports to System32 before main; runtime DLL search is likewise
restricted before any Shell/known-folder initialization.
