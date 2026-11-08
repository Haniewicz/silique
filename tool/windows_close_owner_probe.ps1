# Run only the build of tool/windows_close_owner_probe.dart on an isolated runner.
param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
      [switch]$TimingOnly,
      [switch]$ObservationOnly)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
$root = Join-Path $EvidenceDirectory ('close-probe-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path $EvidenceDirectory 'windows-close-owner-result.json'
$errors = [Collections.Generic.List[string]]::new()
$process = $null
$verify = $null
$clock = $null
$result = [ordered]@{
  fixture = $root
  timing_only = [bool]$TimingOnly
  observation_only = [bool]$ObservationOnly
  close_after_release_ms = $null
  close_wait_elapsed_ms = $null
  process = $null
  process_exit_code = $null
  durable_save_acknowledged = $null
  callback_attempts = $null
  pending_callback_attempts = $null
  pending_save_survived_ms = $null
  pending_save_kept_process = $null
  failed_save_kept_process = $null
  verifier_process = $null
  verifier_process_success = $null
  fresh_process_content_marker = $null
  fresh_process_exact_reopen = $null
  passed = $null
  errors = @()
}
function Get-ProcessState($Process) {
  $state = [ordered]@{
    started = ($null -ne $Process)
    id = $null
    has_exited = $null
    exit_code = $null
    state_error = $null
  }
  if ($null -ne $Process) {
    try {
      $state.id = $Process.Id
      $Process.Refresh()
      $state.has_exited = $Process.HasExited
      if ($state.has_exited) {
        # Only wait once exit is observed. Never infer a zero code from null.
        $Process.WaitForExit()
        $state.exit_code = $Process.ExitCode
      }
    } catch { $state.state_error = $_.Exception.Message }
  }
  return $state
}
function Wait-For([scriptblock]$Condition, [string]$Description) {
  $waitClock = [Diagnostics.Stopwatch]::StartNew()
  while (-not (& $Condition)) {
    if ($waitClock.Elapsed.TotalSeconds -gt 45) { throw "Probe stalled: $Description. No process was force-killed; fixture: $root" }
    Start-Sleep -Milliseconds 10
  }
}
function Request-Close($Process) {
  $Process.Refresh()
  if (-not [SiliqueOwnerCloseProbe]::PostMessage($Process.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
    throw "WM_CLOSE failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
}
try {
  if ($ObservationOnly -and -not $TimingOnly) {
    throw 'ObservationOnly is restricted to TimingOnly baseline measurements'
  }
  New-Item -ItemType Directory $root | Out-Null
  Set-Content (Join-Path $root 'isolated-probe-marker') 'synthetic-only'
  $env:SILIQUE_CLOSE_PROBE_ROOT = $root
  $env:SILIQUE_CLOSE_TIMING_ONLY = if ($TimingOnly) { 'true' } else { 'false' }
  if (-not ('SiliqueOwnerCloseProbe' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SiliqueOwnerCloseProbe {
  [DllImport("user32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
}
'@
  }
  $process = Start-Process -FilePath $Executable -PassThru
  Wait-For { Test-Path (Join-Path $root 'ready') } 'real Home ready'
  Request-Close $process
  if (-not $TimingOnly) {
    Wait-For { Test-Path (Join-Path $root 'failed-save') } 'failed save refusal'
    Start-Sleep -Milliseconds 250
    $state = Get-ProcessState $process
    $result.failed_save_kept_process = ($state.has_exited -eq $false)
    if (-not $result.failed_save_kept_process) { throw 'Save failure exited the app or process state is unknown' }
    Request-Close $process
  }
  Wait-For { Test-Path (Join-Path $root 'save-waiting') } 'save barrier'
  if (-not $TimingOnly) {
    # A repeated native close must not re-enter Home while the accepted save waits.
    Request-Close $process
    $pendingClock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 1000
    $state = Get-ProcessState $process
    $pendingClock.Stop()
    $result.pending_save_kept_process = ($state.has_exited -eq $false)
    if ($result.pending_save_kept_process) {
      $result.pending_save_survived_ms = $pendingClock.ElapsedMilliseconds
    }
    if (-not $result.pending_save_kept_process) { throw 'Window close bypassed a pending save or process state is unknown' }
    $result.pending_callback_attempts = [int](Get-Content (Join-Path $root 'attempts') -Raw).Trim()
    if ($result.pending_callback_attempts -ne 2) { throw 'Concurrent WM_CLOSE repeated the save callback' }
  }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Set-Content (Join-Path $root 'release-save') 'release'
  Wait-For { $process.Refresh(); $process.HasExited } 'natural process exit after durable save'
  $clock.Stop()
} catch {
  $errors.Add($_.Exception.Message)
} finally {
  $result.process = Get-ProcessState $process
  $result.process_exit_code = $result.process.exit_code
  if ($result.process.state_error) { $errors.Add("Close process state: $($result.process.state_error)") }
  if ($null -ne $clock) {
    $clock.Stop()
    $result.close_wait_elapsed_ms = $clock.ElapsedMilliseconds
    if ($result.process.has_exited -eq $true) {
      $result.close_after_release_ms = $clock.ElapsedMilliseconds
      if (-not $TimingOnly -and $clock.ElapsedMilliseconds -ge 3000) {
        $errors.Add("Post-release native close took $($clock.ElapsedMilliseconds) ms (must be <3000)")
      }
    }
  }
  try {
    $result.durable_save_acknowledged = Test-Path (Join-Path $root 'save-durable')
    if (-not $result.durable_save_acknowledged) { $errors.Add('Exited or stalled before durable save acknowledgement') }
    if (Test-Path (Join-Path $root 'attempts')) {
      $result.callback_attempts = [int](Get-Content (Join-Path $root 'attempts') -Raw).Trim()
    }
    if (-not $TimingOnly -and $result.callback_attempts -ne 2) {
      $errors.Add("Expected exactly 2 save callbacks, observed $($result.callback_attempts)")
    }
  } catch { $errors.Add("Fixture evidence: $($_.Exception.Message)") }
  # Verification is diagnostic even after a crash/nonzero close exit. It must
  # never overlap a live or unknown-state close process.
  if ($result.process.has_exited -eq $true) {
    try {
      $verify = Start-Process -FilePath $Executable -ArgumentList '--verify' -PassThru
      Wait-For { $verify.Refresh(); $verify.HasExited } 'fresh-process SQLite reopen'
    } catch { $errors.Add($_.Exception.Message) }
  } else {
    $errors.Add('Fresh-process reopen blocked: close process has not been observed exited')
  }
  if ($result.process_exit_code -ne 0) {
    $errors.Add("Native close exit code $($result.process_exit_code) (null is not success)")
  }
  $result.verifier_process = Get-ProcessState $verify
  if ($result.verifier_process.state_error) { $errors.Add("Verifier process state: $($result.verifier_process.state_error)") }
  $result.verifier_process_success = ($result.verifier_process.has_exited -eq $true -and
    $null -ne $result.verifier_process.exit_code -and $result.verifier_process.exit_code -eq 0)
  try {
    # Dart writes this only after reopening the exact last title/body. A marker
    # alone does not mean the verifier itself survived native teardown.
    $result.fresh_process_content_marker = Test-Path (Join-Path $root 'verified')
  } catch { $errors.Add("Verifier marker: $($_.Exception.Message)") }
  $result.fresh_process_exact_reopen = ($result.fresh_process_content_marker -eq $true -and
    $result.verifier_process_success)
  if (-not $result.fresh_process_exact_reopen) {
    $errors.Add('Fresh process failed exact title/body reopen with verifier exit 0')
  }
  $result.errors = @($errors.ToArray())
  $result.passed = ($errors.Count -eq 0)
  $result | ConvertTo-Json -Depth 6 | Set-Content $report
}
Get-Content $report
if ($errors.Count -gt 0) {
  if ($ObservationOnly -and $TimingOnly) {
    Write-Host "OBSERVATION ONLY: FAILED (not a pass); evidence: $report"
  } else {
    throw ($errors -join '; ')
  }
}
# Retain only this synthetic fixture for diagnostic comparison; no owner data.
