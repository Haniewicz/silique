# Private diagnostic builder: no probes or raw results enter installer assets.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$source = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$baselineSha = 'f11e1fc1b47e775c301264868dd10a7813beb0cc'
$evidence = Join-Path $env:RUNNER_TEMP ('silique-close-' + [guid]::NewGuid().ToString('N'))
$baseline = Join-Path $evidence 'baseline'
New-Item -ItemType Directory $evidence | Out-Null
$errors = [Collections.Generic.List[string]]::new()
$baselineObservations = [Collections.Generic.List[string]]::new()
$runs = [Collections.Generic.List[object]]::new()
$blocked = $false
function Invoke-CloseMeasurement([string]$Name, [string]$Executable,
                                 [switch]$TimingOnly, [switch]$ObservationOnly) {
    if ($ObservationOnly -and ($Name -ne 'baseline' -or -not $TimingOnly)) {
        throw 'ObservationOnly is for the baseline timing control only'
    }
    $directory = Join-Path $evidence $Name
    $path = Join-Path $directory 'windows-close-owner-result.json'
    $invocationError = $null
    $measurement = $null
    # The preserved old source is a measurement control, not a release gate.
    # Keep its actual failures visible without weakening either FINAL probe.
    $failureTarget = $errors
    if ($ObservationOnly) { $failureTarget = $baselineObservations }
    $arguments = @{ Executable=$Executable; EvidenceDirectory=$directory; TimingOnly=$TimingOnly; ObservationOnly=$ObservationOnly }
    try {
        & (Join-Path $PSScriptRoot 'windows_close_owner_probe.ps1') @arguments | Out-Host
    } catch {
        # The probe writes its actual state before throwing. Do not skip strict
        # FINAL merely because timing FINAL failed an assertion after exiting.
        $invocationError = $_.Exception.Message
    }
    try {
        $measurement = Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        $failureTarget.Add("${Name}: missing/unreadable probe evidence: $($_.Exception.Message)")
    }
    if ($invocationError) { $failureTarget.Add("${Name}: $invocationError") }
    if ($null -ne $measurement -and $measurement.passed -ne $true) {
        $failureTarget.Add("${Name}: observed failure: $($measurement.errors -join '; ')")
        if ($Name -eq 'baseline') {
            Write-Host "BASELINE OBSERVED FAILURE (NOT PASS): $($measurement.errors -join '; '); evidence: $path"
        }
    }
    # An exited crash is safe to follow, not a pass. Live, absent, unreadable or
    # unknown-state main/verifier processes are never safe continuation proof.
    $safeToContinue = ($null -ne $measurement -and
        $measurement.process.started -eq $true -and
        $measurement.process.has_exited -eq $true -and
        $measurement.verifier_process.started -eq $true -and
        $measurement.verifier_process.has_exited -eq $true)
    $run = [ordered]@{
        name = $Name
        evidence = $path
        invocation_error = $invocationError
        measurement = $measurement
        safe_to_continue = $safeToContinue
    }
    $runs.Add($run)
    return $run
}
try {
    # Source history was fetched with the existing read-only checkout key, which
    # actions/checkout removes. Do not fetch private code with printed credentials.
    git worktree add --detach $baseline $baselineSha
    Copy-Item (Join-Path $PSScriptRoot 'windows_close_owner_probe.dart') (Join-Path $baseline 'tool/windows_close_owner_probe.dart')
    foreach ($entry in @(@{Name='baseline'; Root=$baseline}, @{Name='final'; Root=$source})) {
        Push-Location $entry.Root
        try {
            Write-Output "CLOSE_TIMING_SOURCE $($entry.Name) $(git rev-parse HEAD)"
            flutter pub get
            flutter build windows --release --target=tool/windows_close_owner_probe.dart --dart-define=SILIQUE_ISOLATED_TEST=true
            $exe = (Resolve-Path 'build/windows/x64/runner/Release/silique.exe').Path
            if ($entry.Name -eq 'baseline') {
                $control = Invoke-CloseMeasurement -Name 'baseline' -Executable $exe -TimingOnly -ObservationOnly
                if (-not $control.safe_to_continue) {
                    $blocked = $true
                    $errors.Add('FINAL blocked: baseline close/verifier has not been observed exited; no process was force-killed')
                    break
                }
            } else {
                $timing = Invoke-CloseMeasurement -Name 'final' -Executable $exe -TimingOnly
                if ($timing.safe_to_continue) {
                    $strict = Invoke-CloseMeasurement -Name 'strict-final' -Executable $exe
                    if (-not $strict.safe_to_continue) {
                        $blocked = $true
                        $errors.Add('Strict FINAL close/verifier has not been observed exited; no process was force-killed')
                    }
                } else {
                    $blocked = $true
                    $errors.Add('Strict FINAL blocked: timing FINAL close/verifier has not been observed exited; no process was force-killed')
                }
            }
        } finally { Pop-Location }
    }
} catch {
    $errors.Add($_.Exception.Message)
} finally {
    # Do not delete a possibly running failed probe. Preserve fixture/worktree
    # for private diagnostics; the disposable hosted runner owns its lifetime.
    Set-Location $source
    Remove-Item Env:SILIQUE_CLOSE_PROBE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:SILIQUE_CLOSE_TIMING_ONLY -ErrorAction SilentlyContinue
    [ordered]@{
        baseline_sha = $baselineSha
        baseline_passed = ($runs.Count -gt 0 -and $runs[0].measurement.passed -eq $true)
        baseline_observations = @($baselineObservations.ToArray())
        acceptance_scope = 'final and strict-final only'
        evidence_directory = $evidence
        runs = @($runs.ToArray())
        blocked = $blocked
        passed = ($errors.Count -eq 0 -and $runs.Count -eq 3 -and -not $blocked)
        errors = @($errors.ToArray())
    } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence 'windows-close-comparison-result.json')
}
# Baseline failure stays in its measurement and baseline_observations, never
# labelled green. Both FINAL failures remain fatal after safe diagnostic runs.
if ($errors.Count -gt 0) { throw ($errors -join '; ') }
# The caller retains flutter clean/pub get and lib/main.dart rebuild before any
# packaging. Nothing from this diagnostic target is a production executable.
