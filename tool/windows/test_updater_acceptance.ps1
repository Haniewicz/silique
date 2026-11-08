param(
  [Parameter(Mandatory)][string]$Setup,
  [Parameter(Mandatory)][string]$Bundle,
  [Parameter(Mandatory)][string]$NativeTest,
  [Parameter(Mandatory)][string]$NegativeControl,
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][int]$Build,
  [Parameter(Mandatory)][string]$Iscc,
  [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Native Windows required; no emulation acceptance.' }
if ($env:GITHUB_ACTIONS -ne 'true' -and $env:SILIQUE_DISPOSABLE_WINDOWS_ACCEPTANCE -ne '1') {
  throw 'This test modifies disposable HKLM/Program Files fixtures. Refusing an owner machine.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'The disposable native CI runner must already be elevated. This is NOT an interactive UAC test.'
}
function Run-Checked([string]$Exe, [string[]]$Arguments) {
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Native acceptance failed ($LASTEXITCODE): $Exe $Arguments" }
}
function Run-Setup([string]$Exe, [string[]]$Arguments) {
  $process = Start-Process $Exe -ArgumentList $Arguments -PassThru
  if (-not $process.WaitForExit(120000)) { throw "Setup fixture timed out: $Exe" }
  if ($process.ExitCode -ne 0) { throw "Setup fixture exit $($process.ExitCode): $Exe" }
}
$keyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{1A327809-A7B2-5F2D-B263-D46B18C17B6B}_is1'
$machineDir = Join-Path $env:ProgramFiles 'Silique'
$root = Join-Path ([IO.Path]::GetTempPath()) ('Silique native Zażółć spaces ' + [guid]::NewGuid())
if (Test-Path $machineDir) { throw 'Refusing an existing installation directory.' }
foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)) {
  foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
    try { $existing = $base.OpenSubKey($keyPath); if ($existing) { $existing.Dispose(); throw 'Refusing existing AppId registration.' } }
    finally { $base.Dispose() }
  }
}
New-Item -ItemType Directory $root | Out-Null
$events = @()
$installed = $false
$completed = $false
try {
  # Real RED negative control: identical tests must reject the reviewed weak
  # attribute-only ancestor pin, not merely fail due to harness setup.
  $negativeLog = Join-Path $root 'negative-control.log'
  $negative = Start-Process $NegativeControl -ArgumentList '--file-tests' -RedirectStandardError $negativeLog -PassThru
  if (-not $negative.WaitForExit(60000)) { throw 'Negative control hung.' }
  if ($negative.ExitCode -ne 86 -or [IO.File]::ReadAllText($negativeLog) -notmatch '!LockWindowsArtifact\(file, kAbcHash, 3\)') {
    throw 'Negative control did not reproduce pre-open writable-ancestor rejection failure.'
  }
  # GREEN: real filesystem locks, guard transfer and bootstrap-vs-consumer exit.
  Run-Checked $NativeTest @((Join-Path $Bundle 'silique_update_guard.exe'))

  Run-Setup $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
  $installed = $true
  $fixture = Join-Path $machineDir 'silique.exe'
  $fixtureAcl = Get-Acl $fixture
  Copy-Item $NativeTest $fixture -Force
  Set-Acl $fixture $fixtureAcl
  Run-Checked $fixture @('--identity', $Version, "$Build", 'yes')
  # Move a COMPLETE, otherwise valid registration to each wrong hive/view.
  # Missing uninstaller/version/ACLs must not make these tests pass by accident.
  $machineBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
  try {
    $valid = $machineBase.OpenSubKey($keyPath)
    $values = @{}
    foreach ($name in $valid.GetValueNames()) { $values[$name] = @($valid.GetValue($name), $valid.GetValueKind($name)) }
    $valid.Dispose()
    foreach ($pair in @(@([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64),
                       @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32))) {
      $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($pair[0], $pair[1])
      try {
        $key = $base.CreateSubKey($keyPath)
        foreach ($name in $values.Keys) { $key.SetValue($name, $values[$name][0], $values[$name][1]) }
        $key.Dispose()
        $machineBase.DeleteSubKeyTree($keyPath, $false)
        Run-Checked $fixture @('--identity', $Version, "$Build", 'no')
      } finally {
        $base.DeleteSubKeyTree($keyPath, $false); $base.Dispose()
        $restored = $machineBase.CreateSubKey($keyPath)
        foreach ($name in $values.Keys) { $restored.SetValue($name, $values[$name][0], $values[$name][1]) }
        $restored.Dispose()
      }
    }
  } finally { $machineBase.Dispose() }
  Run-Checked $fixture @('--identity', $Version, "$Build", 'yes')
  Run-Checked $NativeTest @('--identity', $Version, "$Build", 'no')
  $sibling = "$machineDir copy"
  if (Test-Path $sibling) { throw 'Refusing pre-existing sibling fixture.' }
  New-Item -ItemType Directory $sibling | Out-Null
  try { Copy-Item $NativeTest (Join-Path $sibling 'silique.exe'); Run-Checked (Join-Path $sibling 'silique.exe') @('--identity', $Version, "$Build", 'no') }
  finally { Remove-Item $sibling -Recurse }
  # Stale registration, stale uninstaller and hardlinked/aliased module.
  $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
  $key = $base.OpenSubKey($keyPath, $true)
  try {
    $key.SetValue('DisplayVersion', '0.0.0', [Microsoft.Win32.RegistryValueKind]::String)
    Run-Checked $fixture @('--identity', $Version, "$Build", 'no')
    $key.SetValue('DisplayVersion', $Version, [Microsoft.Win32.RegistryValueKind]::String)
    $uninstall = $key.GetValue('UninstallString')
    $key.SetValue('UninstallString', 'C:\stale\unins000.exe', [Microsoft.Win32.RegistryValueKind]::String)
    Run-Checked $fixture @('--identity', $Version, "$Build", 'no')
    $key.SetValue('UninstallString', $uninstall, [Microsoft.Win32.RegistryValueKind]::String)
  } finally { $key.Dispose(); $base.Dispose() }
  $uninstaller = Join-Path $machineDir 'unins000.exe'
  Move-Item $uninstaller "$uninstaller.missing"
  try { Run-Checked $fixture @('--identity', $Version, "$Build", 'no') }
  finally { Move-Item "$uninstaller.missing" $uninstaller }
  New-Item -ItemType HardLink -Path (Join-Path $machineDir 'module-hardlink.exe') -Target $fixture | Out-Null
  try { Run-Checked $fixture @('--identity', $Version, "$Build", 'no') }
  finally { Remove-Item (Join-Path $machineDir 'module-hardlink.exe') }
  $renamed = "$machineDir-acceptance-$([guid]::NewGuid())"
  Move-Item $machineDir $renamed
  try {
    New-Item -ItemType Junction -Path $machineDir -Target $renamed | Out-Null
    try { Run-Checked $fixture @('--identity', $Version, "$Build", 'no') }
    finally { [IO.Directory]::Delete($machineDir) } # unlink only, NEVER recurse into a junction
  } finally { Move-Item $renamed $machineDir }
  # A section created while the file was reached through the renamed/junction
  # tree can retain that old NT object name after the directory is restored.
  # Use a fresh fixture file for the next positive case, not that stale image
  # section. Keep the strict loaded-image comparison and the alias rejection.
  Remove-Item $fixture
  Copy-Item $NativeTest $fixture
  Set-Acl $fixture $fixtureAcl
  Run-Checked $fixture @('--identity', $Version, "$Build", 'yes')

  # Protected custom installations must update in place, with spaces/Unicode.
  Run-Setup (Join-Path $machineDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
  if (Test-Path $machineDir) { Remove-Item $machineDir -Recurse }
  $machineDir = Join-Path $env:ProgramFiles ('Silique custom Zażółć spaces ' + [guid]::NewGuid())
  Run-Setup $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$machineDir`"")
  $fixture = Join-Path $machineDir 'silique.exe'
  $fixtureAcl = Get-Acl $fixture
  Copy-Item $NativeTest $fixture -Force
  Set-Acl $fixture $fixtureAcl
  Run-Checked $fixture @('--identity', $Version, "$Build", 'yes')
  # HKLM is not sufficient when the registered directory is user-writable.
  $acl = Get-Acl $machineDir
  try {
    $weak = Get-Acl $machineDir
    $weak.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'Modify', 'Allow'))
    Set-Acl $machineDir $weak
    Run-Checked $fixture @('--identity', $Version, "$Build", 'no')
  } finally { Set-Acl $machineDir $acl }

  # Synthetic data/keys/identifiers are outside installation. No real notebook,
  # credential store or owner profile is accessed. Preservation is byte exact.
  $data = Join-Path $root 'synthetic notebook'; New-Item -ItemType Directory $data | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $data 'notebook.sqlite'), [byte[]](0..255))
  [IO.File]::WriteAllText((Join-Path $data 'nova.localKey'), 'SYNTHETIC-LOCAL-KEY-DO-NOT-ROTATE')
  [IO.File]::WriteAllText((Join-Path $data 'identifiers.json'), '{"device":"synthetic-device","installation":"synthetic-installation","pairing":"synthetic-pairing"}')
  [IO.File]::WriteAllText((Join-Path $machineDir 'synthetic-preserve.txt'), 'PRESERVE-INSTALL-EXTRA')
  $before = @{}; Get-ChildItem $data -File | ForEach-Object { $before[$_.Name] = (Get-FileHash $_.FullName).Hash }

  # Test-only compile of THE SAME Inno script. Its barrier is absent from the
  # distributed Setup and pauses after real elevated main-process authentication.
  $acceptanceOut = Join-Path $root 'acceptance setup'; New-Item -ItemType Directory $acceptanceOut | Out-Null
  Run-Checked $Iscc @("/DAppVersion=$Version", "/DAppBuild=$($Build + 1)", "/DBundleDir=$Bundle", "/DOutputDir=$acceptanceOut", '/DNativeAcceptance=1', (Join-Path $PSScriptRoot 'silique.iss'))
  $acceptanceSetup = Join-Path $acceptanceOut "Silique-$Version-Setup-Windows-x64.exe"
  $token = [guid]::NewGuid().ToString('N')
  $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "Local\Silique.Acceptance.Ready.$token")
  $continue = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "Local\Silique.Acceptance.Continue.$token")
  $done = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "Local\Silique.Acceptance.Done.$token")
  $events = @($ready, $continue, $done)
  $stdout = Join-Path $root 'handoff.out'; $stderr = Join-Path $root 'handoff.err'
  $arguments = @('--handoff', "`"$acceptanceSetup`"", $Version, "$Build", (Get-FileHash $acceptanceSetup).Hash.ToLowerInvariant(), "$(Get-Item $acceptanceSetup | Select-Object -ExpandProperty Length)", $token)
  $app = Start-Process $fixture -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  if (-not $app.WaitForExit(60000) -or $app.ExitCode -ne 0) { throw "Native handoff failed: $([IO.File]::ReadAllText($stderr))" }
  if (-not $ready.WaitOne(60000)) { throw 'Actual Inno main did not authenticate after the original app exited.' }
  $lockedFile = [IO.File]::ReadAllText($stdout).Trim()
  if (-not (Test-Path $lockedFile)) { throw 'No actual guarded Setup path.' }
  $cache = Split-Path $lockedFile
  foreach ($operation in @(
      { $f = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); $f.Dispose() },
      { [IO.File]::Delete($lockedFile) },
      { [IO.File]::Move($lockedFile, "$lockedFile.renamed") },
      { [IO.Directory]::Move($cache, "$cache.renamed") }
  )) {
    $blocked = $false; try { & $operation } catch [IO.IOException] { $blocked = $true } catch [UnauthorizedAccessException] { $blocked = $true }
    if (-not $blocked) { throw 'Guard lost a byte/namespace barrier after real app exit.' }
  }
  Run-Checked $fixture @('--instance', 'no')
  # Destination pins must not survive the exited app: Inno needs to rename
  # existing files. This must work while all downloaded-EXE barriers above hold.
  $preserve = Join-Path $machineDir 'synthetic-preserve.txt'
  [IO.File]::Move($preserve, "$preserve.rename-probe")
  [IO.File]::Move("$preserve.rename-probe", $preserve)
  # No concurrent installer may start replacing the same installation.
  $concurrent = Start-Process $Setup -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -PassThru
  if (-not $concurrent.WaitForExit(30000) -or $concurrent.ExitCode -eq 0) { throw 'Concurrent Setup was not rejected.' }
  $continue.Set() | Out-Null
  if (-not $done.WaitOne(120000)) { throw 'Real Inno did not complete same-install replacement.' }
  if (Test-Path (Join-Path $env:ProgramFiles 'Silique')) { throw 'Custom update created an unintended default installation.' }
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    $gate = $null
    try { $gate = [Threading.Mutex]::OpenExisting('Global\Silique.Update.1A327809-A7B2-5F2D-B263-D46B18C17B6B') }
    catch [Threading.WaitHandleCannotBeOpenedException] { break }
    finally { if ($gate) { $gate.Dispose() } }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  if ([DateTime]::UtcNow -ge $deadline) { throw 'Guard did not release after actual Inno consumption.' }
  foreach ($file in Get-ChildItem $Bundle -File -Recurse) {
    $relative = [IO.Path]::GetRelativePath($Bundle, $file.FullName)
    if ((Get-FileHash $file.FullName).Hash -ne (Get-FileHash (Join-Path $machineDir $relative)).Hash) { throw "Wrong same-install bytes: $relative" }
  }
  Get-ChildItem $data -File | ForEach-Object { if ((Get-FileHash $_.FullName).Hash -ne $before[$_.Name]) { throw "Synthetic data changed: $($_.Name)" } }
  if ([IO.File]::ReadAllText((Join-Path $machineDir 'synthetic-preserve.txt')) -ne 'PRESERVE-INSTALL-EXTRA') { throw 'Unexpected install-directory deletion.' }
  # Guard release is proved by successful overwrite/rename/delete afterwards.
  [IO.File]::Move($lockedFile, "$lockedFile.renamed"); [IO.File]::Delete("$lockedFile.renamed")
  [IO.File]::Delete((Join-Path $cache 'guard.exe')); [IO.Directory]::Delete($cache)
  $completed = $true
  @{ nativeWindows = $true; negativeControlRed = $true; byteAndAncestorBarriers = $true; runningModuleOwnership = $true; guardOutlivesBootstrapAndApp = $true; destinationRenameWhileGuarded = $true; realInnoSameInstall = $true; syntheticPreservation = $true; interactiveUac = 'NOT_TESTED'; overTheShoulderUac = 'NOT_TESTED'; realUserNotebookUpgrade = 'NOT_TESTED' } |
    ConvertTo-Json | Set-Content $Report -Encoding utf8NoBOM
} catch {
  # Private build output is sealed by the workflow. Preserve the actual Inno
  # failure, not only a completion-event timeout, without killing Setup.
  if ($acceptanceSetup -and (Test-Path "$acceptanceSetup.log")) {
    [Console]::WriteLine([IO.File]::ReadAllText("$acceptanceSetup.log"))
  }
  throw
} finally {
  if ($events.Count -gt 1) { $events[1].Set() | Out-Null }
  foreach ($event in $events) { $event.Dispose() }
  # On failure retain isolated diagnostics and do not forcibly kill Setup/app.
  if ($installed -and $completed) {
    Run-Setup (Join-Path $machineDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    if (Test-Path $machineDir) { Remove-Item $machineDir -Recurse }
    Remove-Item $root -Recurse
  }
}
Write-Output 'Native Windows updater acceptance gates passed; interactive UAC and owner notebook not tested.'
