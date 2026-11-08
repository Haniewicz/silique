param([switch]$SkipNativeTest)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-Location (Join-Path $PSScriptRoot '..')
if (-not $IsWindows) { throw 'Run this builder on Windows.' }

$versionLine = Select-String -Path pubspec.yaml -Pattern '^version: ([0-9.]+)\+([0-9]+)$'
if (-not $versionLine) { throw 'Missing release version.' }
$version = $versionLine.Matches[0].Groups[1].Value
$build = $versionLine.Matches[0].Groups[2].Value

flutter --version
flutter pub get
if (-not $SkipNativeTest) {
    cmake -S windows/credentials -B build/credential_native -A x64
    cmake --build build/credential_native --config Release
    & build/credential_native/Release/silique_credential_io_test.exe
    flutter test test/windows_updater_test.dart test/windows_handoff_test.dart test/windows_update_home_test.dart test/update_quiescence_test.dart test/updater_test.dart test/updater_dmg_test.dart test/native_updates_test.dart
    # The test runner needs the VM service; release builds intentionally omit it.
    flutter test integration_test/desktop_storage_test.dart -d windows --dart-define=SILIQUE_ISOLATED_TEST=true --dart-define=SILIQUE_EXPECTED_VERSION=$version --dart-define=SILIQUE_EXPECTED_BUILD=$build
    flutter test integration_test/windows_close_input_owner_test.dart -d windows --dart-define=SILIQUE_ISOLATED_TEST=true
    flutter test integration_test/desktop_polish_ux_owner_test.dart -d windows --dart-define=SILIQUE_ISOLATED_TEST=true
    & (Join-Path $PSScriptRoot 'windows_close_compare.ps1')
    # Integration tests have a separate entry point. Always rebuild main.dart.
    flutter clean
    flutter pub get
}
flutter build windows --release --target=lib/main.dart
$bundle = (Resolve-Path 'build/windows/x64/runner/Release').Path
$executable = Join-Path $bundle 'silique.exe'
if (-not $SkipNativeTest) {
    cmake --build build/windows/x64 --config Release --target silique_windows_updater_test silique_windows_updater_negative_control
    $updaterTest = (Resolve-Path 'build/windows/x64/updater_tests/Release/silique_windows_updater_test.exe').Path
    $negativeControl = (Resolve-Path 'build/windows/x64/updater_tests/Release/silique_windows_updater_negative_control.exe').Path
}
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
if ($info.FileMajorPart -ne [int]$version.Split('.')[0] -or $info.FileMinorPart -ne [int]$version.Split('.')[1] -or $info.FileBuildPart -ne [int]$version.Split('.')[2] -or $info.FilePrivatePart -ne [int]$build) {
    throw 'Executable version differs from pubspec.yaml.'
}

# Application-local CRT, as required by Flutter Windows distribution. This
# keeps the per-user installer independent of an administrator installing VC++.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'Visual Studio C++ toolchain not found.' }
$redistRoot = Join-Path $visualStudio 'VC/Redist/MSVC'
$redist = Get-ChildItem $redistRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
    Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
} | Select-Object -First 1
if (-not $redist) { throw 'Visual C++ runtime directory not found.' }
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Copy-Item (Join-Path $redist.FullName $dll) $bundle
}
foreach ($relative in @('silique.exe', 'silique_folder_access.exe', 'silique_update_guard.exe', 'silique_credential_io.dll', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/FontManifest.json')) {
    if (-not (Test-Path (Join-Path $bundle $relative))) { throw "Missing bundle component: $relative" }
}

$output = Join-Path (Get-Location) 'packages/windows'
if (Test-Path $output) { throw 'Use a fresh packages/windows directory.' }
New-Item -ItemType Directory -Path $output | Out-Null
$zip = Join-Path $output "Silique-$version-Windows-x64.zip"
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -CompressionLevel Optimal
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 is required.' }
& $iscc "/DAppVersion=$version" "/DAppBuild=$build" "/DBundleDir=$bundle" "/DOutputDir=$output" 'tool/windows/silique.iss'
$setup = Join-Path $output "Silique-$version-Setup-Windows-x64.exe"

if (-not $SkipNativeTest) {
    & (Join-Path $PSScriptRoot 'windows/test_updater_acceptance.ps1') -Setup $setup -Bundle $bundle `
        -NativeTest $updaterTest -NegativeControl $negativeControl -Version $version -Build ([int]$build) `
        -Iscc $iscc -Report (Join-Path $output 'windows-updater-acceptance.json')
    [Console]::WriteLine([IO.File]::ReadAllText((Join-Path $output 'windows-updater-acceptance.json')))
}

$files = @($zip, $setup) | ForEach-Object {
    @{ name = [IO.Path]::GetFileName($_); sha256 = (Get-FileHash $_ -Algorithm SHA256).Hash.ToLowerInvariant(); size = (Get-Item $_).Length }
}
@{ version = $version; build = [int]$build; architecture = 'x64'; nativeStorageTest = (-not $SkipNativeTest); nativeUpdaterTest = (-not $SkipNativeTest); installerSmoke = (-not $SkipNativeTest); files = @($files) } |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $output 'windows-build.json') -Encoding utf8NoBOM
$files | ForEach-Object { "$($_.sha256)  $($_.name)" } | Set-Content (Join-Path $output 'SHA256SUMS-Windows.txt') -Encoding utf8NoBOM
Write-Output "Windows packages built; native acceptance enabled: $(-not $SkipNativeTest)."
