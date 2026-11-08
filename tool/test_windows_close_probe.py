"""Portable source-contract checks; not a substitute for Windows execution.

Run: python3 -B tool/test_windows_close_probe.py
No PowerShell, Flutter, owner data, or subprocess launches are needed.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROBE = (ROOT / "tool/windows_close_owner_probe.ps1").read_text()
COMPARE = (ROOT / "tool/windows_close_compare.ps1").read_text()
BUILDER = (ROOT / "tool/build_windows.ps1").read_text()


class ProbeContractTests(unittest.TestCase):
    def test_failure_evidence_precedes_terminal_throw(self):
        self.assertIn("finally {", PROBE)
        write = PROBE.index("$result | ConvertTo-Json")
        terminal_throw = PROBE.index("throw ($errors -join")
        self.assertLess(write, terminal_throw)
        self.assertIn("$result.errors = @($errors.ToArray())", PROBE)
        self.assertIn("$result.passed = ($errors.Count -eq 0)", PROBE)

    def test_verifier_follows_observed_exit_not_zero_exit(self):
        self.assertIn("if ($result.process.has_exited -eq $true)", PROBE)
        tail = PROBE[PROBE.index("if ($result.process.has_exited -eq $true)"):]
        launch = tail.index("-ArgumentList '--verify'")
        self.assertNotIn("throw", tail[:launch])
        self.assertNotIn("exit_code -eq 0", tail[:launch])
        self.assertIn("$result.verifier_process = Get-ProcessState $verify", tail)
        self.assertIn("$result.fresh_process_content_marker =", tail)
        self.assertIn("$result.verifier_process_success =", tail)
        self.assertIn("$result.fresh_process_exact_reopen =", tail)

    def test_observation_is_explicit_and_timing_only(self):
        self.assertIn("[switch]$ObservationOnly", PROBE)
        guard = PROBE.index("if ($ObservationOnly -and -not $TimingOnly)")
        launch = PROBE.index("$process = Start-Process")
        self.assertLess(guard, launch)
        self.assertIn("if ($ObservationOnly -and $TimingOnly)", PROBE)
        self.assertIn("OBSERVATION ONLY: FAILED", PROBE)
        self.assertNotRegex(PROBE, r"(?i)exitcodefallback|exit_code\s*=\s*0")

    def test_final_assertions_remain_strict_and_observed(self):
        for contract in (
            "$state.exit_code = $Process.ExitCode", "Start-Sleep -Milliseconds 250",
            "Start-Sleep -Milliseconds 1000", "'failed-save'", "'save-durable'",
            "$result.failed_save_kept_process = ($state.has_exited -eq $false)",
            "$result.pending_save_kept_process = ($state.has_exited -eq $false)",
            "$result.pending_callback_attempts -ne 2",
            "$result.callback_attempts -ne 2",
            "$clock.ElapsedMilliseconds -ge 3000",
            "$result.process_exit_code -ne 0",
            "$result.verifier_process.exit_code -eq 0",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, PROBE)
        self.assertNotRegex(PROBE, r"fresh_process_exact_reopen\s*=\s*\$true")
        self.assertNotRegex(PROBE, r"failed_save_kept_process\s*=\s*\(-not")
        for forbidden in ("Stop-Process", ".Kill(", "taskkill", "ExitProcess", "mutex"):
            self.assertNotIn(forbidden, PROBE)


class CompareContractTests(unittest.TestCase):
    def test_baseline_failure_is_retained_separately_from_final_acceptance(self):
        self.assertIn('$baselineObservations =', COMPARE)
        self.assertIn('$failureTarget = $errors', COMPARE)
        self.assertIn('if ($ObservationOnly) { $failureTarget = $baselineObservations }', COMPARE)
        self.assertIn('baseline_observations = @($baselineObservations.ToArray())', COMPARE)
        self.assertIn('baseline_passed =', COMPARE)
        self.assertIn("acceptance_scope = 'final and strict-final only'", COMPARE)
        self.assertIn('if ($errors.Count -gt 0) { throw', COMPARE)

    def test_observation_mode_is_used_only_for_baseline(self):
        self.assertTrue("if ($entry.Name -eq 'baseline')" in COMPARE,
                        "baseline must have its own observation-only branch")
        branch = COMPARE.split("if ($entry.Name -eq 'baseline')", 1)[1]
        self.assertIn("-Name 'baseline' -Executable $exe -TimingOnly -ObservationOnly", branch)
        self.assertEqual(COMPARE.count("-TimingOnly -ObservationOnly"), 1)
        self.assertIn("BASELINE OBSERVED FAILURE (NOT PASS)", COMPARE)
        self.assertIn("$errors.Add", COMPARE)

    def test_final_timing_failure_cannot_skip_strict_after_exit(self):
        self.assertTrue("$timing = Invoke-CloseMeasurement -Name 'final'" in COMPARE,
                        "timing result must be captured even when it fails")
        timing = COMPARE.index("$timing = Invoke-CloseMeasurement -Name 'final'")
        strict = COMPARE.index("Invoke-CloseMeasurement -Name 'strict-final'")
        between = COMPARE[timing:strict]
        self.assertIn("if ($timing.safe_to_continue)", between)
        self.assertNotIn(".passed", between)
        self.assertNotIn("throw", between)
        self.assertLess(strict, COMPARE.index("throw ($errors -join"))

    def test_live_or_unknown_main_or_verifier_blocks_next(self):
        self.assertTrue("$safeToContinue =" in COMPARE,
                        "continuation must depend on process exit evidence")
        safety = COMPARE.split("$safeToContinue =", 1)[1].split("return ", 1)[0]
        for check in ("$measurement.process.started -eq $true",
                      "$measurement.process.has_exited -eq $true",
                      "$measurement.verifier_process.started -eq $true",
                      "$measurement.verifier_process.has_exited -eq $true"):
            self.assertIn(check, safety)
        self.assertIn("if (-not $control.safe_to_continue)", COMPARE)
        self.assertIn("$blocked = $true", COMPARE)
        for forbidden in ("Stop-Process", ".Kill(", "taskkill", "ExitProcess", "mutex"):
            self.assertNotIn(forbidden, COMPARE)

    def test_comparison_records_errors_before_throw_and_rebuild_is_retained(self):
        self.assertTrue("'windows-close-comparison-result.json'" in COMPARE,
                        "comparison must retain aggregate failure evidence")
        self.assertLess(COMPARE.index("ConvertTo-Json"), COMPARE.index("throw ($errors -join"))
        self.assertIn("runs = @($runs.ToArray())", COMPARE)
        self.assertIn("passed = ($errors.Count -eq 0", COMPARE)
        self.assertIn("Get-Content $path -Raw | ConvertFrom-Json", COMPARE)
        compare = BUILDER.index("'windows_close_compare.ps1'")
        clean = BUILDER.index("flutter clean", compare)
        rebuild = BUILDER.index("flutter build windows --release --target=lib/main.dart", clean)
        package = BUILDER.index("Compress-Archive", rebuild)
        self.assertLess(compare, clean)
        self.assertLess(clean, rebuild)
        self.assertLess(rebuild, package)


if __name__ == "__main__":
    unittest.main()
