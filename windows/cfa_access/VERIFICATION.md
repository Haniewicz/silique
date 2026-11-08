# Native verification on the owner's Windows machine

All runs below were **unelevated**. No `--request`, elevated `--apply`, live UAC,
Defender preference mutation, signing, publication, application launch, or
application restart was performed. A real installed `silique.exe` was copied
byte-for-byte **only to the isolated scratch build**, never executed, and its
SHA-256 was compared with the installed source copy.

## Real toolchain and artifacts

- Compiler: MSVC **19.44.35222.0**, x64, VS 2022 BuildTools.
- CMake executable:
  `C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe`
- Source:
  `C:/Users/Ultro/Desktop/Programowanie/Silique/silique-app/windows/cfa_access`
- Build directory:
  `C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native`
- Helper:
  `C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native/Release/silique_folder_access.exe`
- Native tests:
  `C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native/Release/silique_cfa_tests.exe`

Actual command forms (the absolute CMake/CTest tool paths above were used):

```text
cmake -S C:/Users/Ultro/Desktop/Programowanie/Silique/silique-app/windows/cfa_access -B C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native -G "Visual Studio 17 2022" -A x64
cmake --build C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native --config Release
ctest --test-dir C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native -C Release --output-on-failure -V
python C:/Users/Ultro/Desktop/Programowanie/Silique/silique-app/windows/cfa_access/verify_readonly.py C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native/Release/silique_folder_access.exe "C:/Users/Ultro/Documents/Silique Vaults"
```

## Observed RED -> GREEN stages

These were compiled/executed failures, not asserted hypothetical failures:

| Slice | Observed RED | Subsequent GREEN |
|---|---|---|
| Profile/slash/case and root matching | `FAIL after 1 checks: profile/slash/case normalization missing` | `PASS 4 checks` |
| Typed event decoding/freshness | `FAIL after 5 checks: typed Defender 1123 decoding missing` | `PASS 15 checks` |
| CLI, gates, results and JSON | `FAIL after 16 checks: inspect CLI parsing missing` | `PASS 47 checks` |
| Protected ownership/DACL analysis | `FAIL after 48 checks: trusted bundle descriptor validation missing` | ACL checks passed; next slice failed at 58 |
| Encoded safe-data PowerShell plan | `FAIL after 58 checks: safe PowerShell plan missing` | `PASS 71 checks` |
| Native file pins/final path + read-only Event Log | `FAIL after 73 checks: native file pin/final-path validation missing` | `PASS 75 checks` |
| Self-derived sibling identity | `FAIL after 76 checks: self-derived sibling identity missing` | `PASS 78 checks` |
| Reserved DOS names | `FAIL after 98 checks: ambiguous/device/reserved/traversal path must fail` | Next Unicode regression failed at 100 |
| Invalid UTF-16 | `FAIL after 100 checks: invalid UTF-16 path must fail` | `PASS 104 checks` |
| Actual protected system dependency guard | `FAIL after 108 checks: OS-owned hardlinked PowerShell/modules must validate read-only` | `PASS 108 checks` |
| Case-sensitive directory ambiguity | `FAIL after 110 checks: case-sensitive directory cannot use case-insensitive event identity` | `PASS 111 checks` |

The final system-dependency regression found a real compatibility issue:
Windows' actual PowerShell EXE and CimCmdlets manifest each have **2 hardlinks**
(WinSxS servicing), so indiscriminately applying the bundle hardlink rule to OS
files refused every apply. The fix permits hardlinks **only for pinned,
trusted-owned/DACL-verified system PowerShell dependencies**, not bundle files.
The real read-only system dependency check now passes. No privileged operation
was needed to find or test that correction.

Final CTest output:

```text
1: PASS 111 checks
1/1 Test #1: silique_cfa_native ............... Passed
100% tests passed, 0 tests failed out of 1
```

This includes pure path/event/time, argument/injection, ACL and result/gate
checks; read-only native path/log/system-file checks; and an actual system
PowerShell **AST parser-only** check of the encoded generated operation. Parsing
treats that operation as data, not an invocation. Inert-platform tests cover
cancellation, absent/stale evidence, no elevation, unsafe installations,
readback/policy failure, and the verified-success mapping.

## Actual CLI outputs

Smoke script first verified `TokenIsElevated=0`, then checked it again before
every invocation. For both existing roots `C:/Users/Ultro/Silique Vaults` and
`C:/Users/Ultro/Documents/Silique Vaults`, real `--inspect` returned:

```json
{"status":"unconfirmed","executable":"C:\\Users\\Ultro\\AppData\\Local\\hermes\\cache\\scratch\\silique-cfa-native\\Release\\silique.exe","message":"No fresh matching Defender block event 1123 was confirmed; no change was made."}
```

Exit was **0**, stderr empty. The sibling is deliberately the isolated scratch
application copy, not the installed application from historical events; no
recent matching event was claimed or synthesized.

Real **unelevated** `--apply` returned:

```json
{"status":"failed","executable":"C:\\Users\\Ultro\\AppData\\Local\\hermes\\cache\\scratch\\silique-cfa-native\\Release\\silique.exe","message":"The internal apply mode requires elevation; no change was made."}
```

Its controlled internal exit was **5458179** (`0x534903`), stderr empty.
Additional apply arguments were refused with public exit 1 / `failed`, as were
read-only UNC and wildcard-root inspections. Final result:

```text
PASS 5 CLI smoke checks; no live UAC, no elevated operation.
```

A source example path with an extra `Documents/Silique/` component did not exist
on this machine; smoke testing stopped before launching any helper, then used
the verified existing roots above. A diagnostic ctypes token check initially
needed explicit 64-bit HANDLE signatures; the checked-in smoke script has them.
Neither probe reached an elevated path or changed settings.

## PE/static audit

Actual `dumpbin /dependents`, `/imports` and `/loadconfig` checks verified:

- x64 PE machine **0x8664**.
- No VCRUNTIME/MSVCP/UCRTBASE imports: helper CRT is static.
- Dependent Load Flag **0800** (System32 static-import search), CFG instrumented.
- Dependencies only `ADVAPI32.dll`, `SHELL32.dll`, `ole32.dll`, `wevtapi.dll`,
  `KERNEL32.dll`.
- Embedded signature directory `[0, 0]`: intentionally unsigned.

Final measured files:

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `silique_folder_access.exe` | 278016 | `f7806167d3d1e6cd01fb30b15a73540e889d4ffb81343eaa96345a5dd4019477` |
| `silique_cfa_tests.exe` | 367104 | `1bef81d8e1a5a256973d3a1cb2f657465e969514439189e2de495a0d05f60163` |

Source scan found no hardcoded secrets, `shell=True`/os.system/eval/exec/unsafe
pickle, or forbidden Defender mutations. `git diff --check` passed for the
owned source/CMake/packaging paths. Other agents' Dart/generated/installer edits
were not modified or reverted here.

## Retained real logs

Under `C:/Users/Ultro/AppData/Local/hermes/cache/scratch/silique-cfa-native/`:

- `native-build.log`
- `native-ctest.log`
- `readonly-smoke.log`
- `binary-audit.json`
- `Testing/Temporary/LastTest.log` (CTest's own log)

## Deliberately unverified / handoff

No positive live `confirmed` event was forced; no UAC cancellation/success was
interactively exercised; no actual Add/Get preference operation ran. Full
protected-install elevated E2E requires separate authorized interactive testing.
The Flutter bundle/installer build is owned by the parent task; this work built
and ran the standalone native targets. Top-level CMake and packaging checks were
updated to include/require the sibling helper, but no release package was
published or signed. The current JSON keeps the agreed three fields; no
`canRequest` extension was added.
