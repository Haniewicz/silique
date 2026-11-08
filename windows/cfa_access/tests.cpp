#include "cfa_core.h"
#include "cfa_windows.h"
#include <iostream>
#include <stdexcept>
#include <sddl.h>
#include <wincrypt.h>

bool ParsePlanOnly(const cfa::PowerShellPlan& plan) {
  const auto payload = plan.arguments.substr(plan.arguments.find_last_of(L' ') + 1);
  // The generated operation is parser INPUT, never invoked or evaluated.
  const std::wstring parser = L"$PSModuleAutoLoadingPreference='None';$ErrorActionPreference='Stop';"
      L"$source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + payload + L"'));"
      L"$tokens=$null;$errors=$null;"
      L"[void][System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);"
      L"if(@($errors).Count -ne 0){exit 91};exit 0";
  DWORD length = 0;
  auto bytes = reinterpret_cast<const BYTE*>(parser.data());
  DWORD size = static_cast<DWORD>(parser.size() * sizeof(wchar_t));
  if (!CryptBinaryToStringW(bytes, size, CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &length)) return false;
  std::wstring encoded(length, L'\0');
  if (!CryptBinaryToStringW(bytes, size, CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, encoded.data(), &length)) return false;
  if (!encoded.empty() && encoded.back() == L'\0') encoded.pop_back();
  wchar_t system[32768]{};
  UINT count = GetSystemDirectoryW(system, 32768);
  if (!count || count >= 32768) return false;
  std::wstring executable = std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::wstring command = L"\"" + executable + L"\" -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                      nullptr, system, &startup, &process)) return false;
  DWORD waited = WaitForSingleObject(process.hProcess, 15000);
  if (waited != WAIT_OBJECT_0) { TerminateProcess(process.hProcess, 92); WaitForSingleObject(process.hProcess, 5000); }
  DWORD code = 1;
  bool success = waited == WAIT_OBJECT_0 && GetExitCodeProcess(process.hProcess, &code) && code == 0;
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return success;
}

bool TrustedSddl(const wchar_t* text, bool ancestor = false) {
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(text, SDDL_REVISION_1, &sd, nullptr))
    throw std::runtime_error("Invalid SDDL test fixture");
  bool result = cfa::TrustedDescriptor(sd, ancestor);
  LocalFree(sd);
  return result;
}

int checks = 0;
void Check(bool condition, const char* message) {
  ++checks;
  if (!condition) throw std::runtime_error(message);
}
struct FakePlatform final : cfa::Platform {
  bool elevated = false, prepared = true, protected_install = true, verified = true;
  cfa::Evidence evidence = cfa::Evidence::Confirmed;
  cfa::Status elevated_result = cfa::Status::Allowed;
  int preparation_calls = 0, evidence_calls = 0, uac_calls = 0, write_calls = 0;
  std::optional<std::wstring> confirmed_root;
  bool Elevated() override { return elevated; }
  bool Prepare(const std::optional<std::wstring>&) override { ++preparation_calls; return prepared; }
  bool ProtectedInstall() override { return protected_install; }
  cfa::Evidence Confirm(const std::optional<std::wstring>& root) override {
    ++evidence_calls; confirmed_root = root; return evidence;
  }
  cfa::Status RequestElevation() override { ++uac_calls; return elevated_result; }
  bool AddAndVerify() override { ++write_calls; return verified; }
};

int main() {
  try {
    cfa::PathContext context{L"C:\\Users\\Owner", {{L"\\Device\\HarddiskVolume3", L"C:"}}};
    auto path = cfa::NormalizePath(L"%uSeRpRoFiLe%/Documents/Silique Vaults/", context);
    Check(path && cfa::SamePath(*path, L"c:\\users\\owner\\documents\\silique vaults"), "profile/slash/case normalization missing");
    Check(cfa::WithinRoot(L"C:\\Vault\\notes\\a.md", L"c:\\vault"), "child path must match");
    Check(cfa::WithinRoot(L"C:\\Vault", L"c:\\vault"), "root itself must match");
    Check(!cfa::WithinRoot(L"C:\\Vault-lookalike\\a", L"C:\\Vault"), "prefix lookalike must fail");
    EVT_VARIANT system[EvtSystemPropertyIdEND]{};
    EVT_VARIANT data[2]{};
    system[EvtSystemProviderName].Type = EvtVarTypeString;
    system[EvtSystemProviderName].StringVal = cfa::kProvider;
    system[EvtSystemChannel].Type = EvtVarTypeString;
    system[EvtSystemChannel].StringVal = cfa::kChannel;
    system[EvtSystemEventID].Type = EvtVarTypeUInt16;
    system[EvtSystemEventID].UInt16Val = 1123;
    system[EvtSystemTimeCreated].Type = EvtVarTypeFileTime;
    const std::uint64_t now = 134000000000000000ULL;
    system[EvtSystemTimeCreated].FileTimeVal = now - 1;
    data[0].Type = data[1].Type = EvtVarTypeString;
    data[0].StringVal = L"C:\\Apps\\Silique\\silique.exe";
    data[1].StringVal = L"%USERPROFILE%\\Documents\\Silique Vaults\\note.md";
    auto event = cfa::DecodeEvent(system, EvtSystemPropertyIdEND, data, 2);
    Check(event.has_value(), "typed Defender 1123 decoding missing");
    const std::wstring target = L"c:\\apps\\silique\\silique.exe";
    const std::wstring root = L"C:\\Users\\Owner\\Documents\\Silique Vaults";
    Check(cfa::MatchesEvent(*event, target, root, now, context), "fresh matching event must confirm");
    Check(cfa::MatchesEvent(*event, target, std::nullopt, now, context), "apply permits any valid event root");
    event->time = now - cfa::kFreshTicks;
    Check(cfa::MatchesEvent(*event, target, root, now, context), "exact five minute boundary");
    --event->time;
    Check(!cfa::MatchesEvent(*event, target, root, now, context), "stale event must fail");
    event->time = now + 1;
    Check(!cfa::MatchesEvent(*event, target, root, now, context), "future event must fail");
    event->time = now;
    Check(!cfa::MatchesEvent(*event, target + L".bad", root, now, context), "wrong process must fail");
    Check(!cfa::MatchesEvent(*event, target, root + L"2", now, context), "wrong root must fail");
    system[EvtSystemEventID].UInt16Val = 1124;
    Check(!cfa::DecodeEvent(system, EvtSystemPropertyIdEND, data, 2), "audit event is not a block");
    system[EvtSystemEventID].UInt16Val = 1123;
    data[0].Type |= EVT_VARIANT_TYPE_ARRAY;
    Check(!cfa::DecodeEvent(system, EvtSystemPropertyIdEND, data, 2), "duplicate/array process field must fail");
    data[0].Type = EvtVarTypeNull;
    Check(!cfa::DecodeEvent(system, EvtSystemPropertyIdEND, data, 2), "missing named process must fail");
    Check(cfa::ParseArguments({L"--inspect", root}).mode == cfa::Mode::Inspect, "inspect CLI parsing missing");
    Check(cfa::ParseArguments({L"--request", root}).mode == cfa::Mode::Request, "request CLI parsing");
    Check(cfa::ParseArguments({L"--apply"}).mode == cfa::Mode::Apply, "fixed internal apply parsing");
    for (const auto& arguments : std::vector<std::vector<std::wstring>>{
        {}, {L"--apply", root}, {L"--apply", L"--target", target}, {L"--inspect"},
        {L"--request", root, L"-Command", L"evil"}, {L"--dry-run", root}, {L"--INSPECT", root}}) {
      Check(cfa::ParseArguments(arguments).mode == cfa::Mode::Invalid, "reject extra/unknown/missing CLI data");
    }
    Check(cfa::MapApplyExit(cfa::kApplyAllowed) == cfa::Status::Allowed, "verified child result mapping");
    Check(cfa::MapApplyExit(cfa::kApplyUnconfirmed) == cfa::Status::Unconfirmed, "stale elevated result mapping");
    for (DWORD code : {DWORD(0), DWORD(1), DWORD(778), DWORD(STILL_ACTIVE), cfa::kApplyFailed})
      Check(cfa::MapApplyExit(code) == cfa::Status::Failed, "unknown child exit cannot mean success");
    Check(cfa::MapShellError(ERROR_CANCELLED) == cfa::Status::Cancelled, "UAC cancellation mapping");
    Check(cfa::MapShellError(ERROR_ACCESS_DENIED) == cfa::Status::Failed, "UAC failure mapping");
    FakePlatform fake;
    auto inspect = cfa::ParseArguments({L"--inspect", root});
    Check(cfa::Run(inspect, fake).status == cfa::Status::Confirmed, "read-only inspection confirms event");
    Check(cfa::Json(cfa::Run(inspect, fake), target).find("\"canRequest\":true") != std::string::npos,
          "confirmed protected inspection must expose canRequest to the UI");
    Check(fake.write_calls == 0 && fake.uac_calls == 0, "inspect cannot write or elevate");
    fake.protected_install = false;
    Check(cfa::Run(inspect, fake).status == cfa::Status::Confirmed, "portable inspection still diagnoses");
    Check(cfa::Json(cfa::Run(inspect, fake), target).find("\"canRequest\":false") != std::string::npos,
          "confirmed legacy inspection must not enable the UAC button");
    auto request = cfa::ParseArguments({L"--request", root});
    auto refused = cfa::Run(request, fake);
    Check(refused.status == cfa::Status::Failed && std::string(refused.message).find("Program Files") != std::string::npos,
          "unprotected install fails with actionable message");
    Check(fake.uac_calls == 0 && fake.write_calls == 0, "no UAC/write for unprotected install");
    fake.protected_install = true;
    fake.evidence = cfa::Evidence::Absent;
    Check(cfa::Run(request, fake).status == cfa::Status::Unconfirmed && fake.uac_calls == 0, "no UAC without fresh evidence");
    fake.evidence = cfa::Evidence::Error;
    Check(cfa::Run(request, fake).status == cfa::Status::Failed && fake.uac_calls == 0, "event read failure fails closed");
    fake.evidence = cfa::Evidence::Confirmed;
    fake.elevated_result = cfa::Status::Cancelled;
    Check(cfa::Run(request, fake).status == cfa::Status::Cancelled && fake.write_calls == 0, "UAC cancellation never reports allowed");
    auto apply = cfa::ParseArguments({L"--apply"});
    int calls = fake.preparation_calls;
    Check(cfa::Run(apply, fake).status == cfa::Status::Failed && fake.preparation_calls == calls && fake.write_calls == 0,
          "unelevated apply refuses before privileged work");
    fake.elevated = true;
    fake.evidence = cfa::Evidence::Absent;
    Check(cfa::Run(apply, fake).status == cfa::Status::Unconfirmed && fake.write_calls == 0, "apply rechecks freshness");
    fake.evidence = cfa::Evidence::Confirmed;
    fake.verified = false;
    Check(cfa::Run(apply, fake).status == cfa::Status::Failed && !fake.confirmed_root, "readback/policy failure never means allowed");
    fake.verified = true;
    Check(cfa::Run(apply, fake).status == cfa::Status::Allowed, "only verified apply succeeds");
    Check(cfa::Json({cfa::Status::Failed, "No change."}, L"C:\\Apps\\Silique\\silique.exe") ==
          "{\"status\":\"failed\",\"executable\":\"C:\\\\Apps\\\\Silique\\\\silique.exe\",\"message\":\"No change.\",\"canRequest\":false}\n", "JSON CLI contract");
    Check(TrustedSddl(L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)"), "trusted bundle descriptor validation missing");
    Check(!TrustedSddl(L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FW;;;BU)"), "users write permission rejects bundle");
    Check(!TrustedSddl(L"O:BAG:BAD:P(A;;FA;;;AU)"), "authenticated users write rejects bundle");
    Check(!TrustedSddl(L"O:BAG:BAD:P(A;;WD;;;WD)"), "everyone WRITE_DAC rejects bundle");
    Check(!TrustedSddl(L"O:S-1-5-21-1-2-3-1001G:BAD:P(A;;FA;;;BA)"), "untrusted owner can rewrite DACL");
    Check(!TrustedSddl(L"O:BAG:BAD:NO_ACCESS_CONTROL"), "NULL DACL rejects bundle");
    Check(TrustedSddl(L"O:BAG:BAD:P(A;OICIIO;GA;;;CO)(A;;FA;;;BA)(A;;FRFX;;;BU)"), "inherit-only creator ACE does not grant current access");
    Check(!TrustedSddl(L"O:BAG:BAD:P(D;;FW;;;BU)(A;;FW;;;BU)(A;;FA;;;BA)"), "conservative deny/allow ambiguity fails closed");
    Check(TrustedSddl(L"O:BAG:BAD:P(A;;0x00000004;;;BU)(A;;FA;;;BA)", true), "ancestor create-directory only is not replacement permission");
    Check(!TrustedSddl(L"O:BAG:BAD:P(A;;0x00000040;;;BU)(A;;FA;;;BA)", true), "ancestor DELETE_CHILD rejects bundle");
    auto plan = cfa::BuildPowerShellPlan(L"C:\\Windows\\System32", L"C:\\Program Files\\Silique's $app; ok\\silique.exe", context);
    Check(plan.has_value(), "safe PowerShell plan missing");
    Check(plan->executable == L"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "absolute system PowerShell only");
    Check(plan->arguments.rfind(L"-NoLogo -NoProfile -NonInteractive -EncodedCommand ", 0) == 0, "encoded noninteractive fixed flags");
    Check(plan->arguments.find(L"Silique") == std::wstring::npos && plan->script.find(L"Silique") == std::wstring::npos,
          "target must occur only as base64 data, never interpolated script text");
    Check(plan->script.find(L"Defender\\Add-MpPreference -ControlledFolderAccessAllowedApplications") != std::wstring::npos &&
          plan->script.find(L"Defender\\Get-MpPreference") != std::wstring::npos &&
          plan->script.find(L"[StringComparison]::OrdinalIgnoreCase") != std::wstring::npos &&
          plan->script.find(L"exit 21") != std::wstring::npos, "narrow add, exact readback and controlled success code");
    Check(plan->script.find(L"$PSModuleAutoLoadingPreference='None'") != std::wstring::npos &&
          plan->script.find(L"Import-Module -Name") != std::wstring::npos, "no user-module autoload");
    for (const auto& bad : {L"\\\\server\\app\\silique.exe", L"C:\\Apps\\*\\silique.exe", L"C:\\Apps\\[x]\\silique.exe",
        L"C:\\Apps\\x.exe:stream", L"C:\\Apps\\x\n.exe", L"C:\\Apps\\x\";evil.exe", L"C:relative\\silique.exe"}) {
      Check(!cfa::BuildPowerShellPlan(L"C:\\Windows\\System32", bad, context), "reject wildcard/UNC/control/stream/injection target");
    }
    Check(!cfa::BuildPowerShellPlan(L"C:\\User\\PowerShell", target, context), "reject non-system-directory plan");
    auto native_context = cfa::SystemPathContext();
    wchar_t module[32768]{};
    Check(GetModuleFileNameW(nullptr, module, 32768) != 0, "read own native test executable path");
    Check(cfa::ValidateReadOnlyPath(module, false, native_context), "native file pin/final-path validation missing");
    Check(!cfa::ValidateReadOnlyPath(L"\\\\localhost\\C$\\Windows", true, native_context), "native UNC validation fail closed");
    Check(cfa::QueryEvidence(L"C:\\NoSuchSiliqueInstallationCfaTest\\silique.exe", std::nullopt, native_context) == cfa::Evidence::Absent,
          "read-only native event-query integration must find no matching executable");
    cfa::NativePlatform native;
    std::wstring own_module(module);
    std::wstring expected_sibling = own_module.substr(0, own_module.find_last_of(L'\\') + 1) + L"silique.exe";
    Check(cfa::SamePath(native.executable(), expected_sibling), "self-derived sibling identity missing");
    Check(!native.ProtectedInstall(), "unprepared portable bundle cannot be trusted");
    Check(!native.Prepare(std::nullopt), "test executable cannot impersonate helper filename");
    auto nt = cfa::NormalizePath(L"\\Device\\HarddiskVolume3\\Apps\\Silique\\silique.exe", context);
    Check(nt && cfa::SamePath(*nt, L"C:\\Apps\\Silique\\silique.exe"), "known NT device mapping");
    Check(!cfa::NormalizePath(L"\\Device\\HarddiskVolume300\\Apps\\silique.exe", context), "NT device lookalike fails closed");
    auto ambiguous = context;
    ambiguous.devices.push_back({L"\\Device\\HarddiskVolume3", L"D:"});
    Check(!cfa::NormalizePath(L"\\Device\\HarddiskVolume3\\Apps\\silique.exe", ambiguous), "ambiguous NT aliases fail closed");
    for (const auto& spelling : {L"C:/Vault/a.md", L"\\\\?\\C:\\Vault\\a.md", L"\\??\\C:\\Vault\\a.md"}) {
      auto normalized = cfa::NormalizePath(spelling, context);
      Check(normalized && cfa::SamePath(*normalized, L"c:\\vault\\a.md"), "local DOS spelling normalization");
    }
    for (const auto& bad_path : {L"\\\\server\\share\\a", L"\\\\?\\UNC\\server\\share\\a", L"\\\\.\\C:\\a",
        L"C:\\Vault\\..\\outside", L"C:\\Vault\\.\\a", L"C:\\Vault\\a.\\file", L"C:\\Vault\\a \\file",
        L"C:\\Vault\\a\\\\file", L"%USERPROFILE%lookalike\\a", L"%APPDATA%\\a", L"C:\\Vault\\a:stream",
        L"C:\\NUL.txt", L"C:\\COM1", L"C:\\CONIN$", L"C:\\CONOUT$"})
      Check(!cfa::NormalizePath(bad_path, context), "ambiguous/device/reserved/traversal path must fail");
    Check(!cfa::NormalizePath(std::wstring(L"C:\\Vault\\") + wchar_t(0xd800), context), "invalid UTF-16 path must fail");
    Check(!cfa::NormalizePath(std::wstring(L"C:\\Vault\\") + wchar_t(0xdc00), context), "orphan low surrogate path must fail");
    Check(!cfa::NormalizePath(std::wstring(L"C:\\Vault\\a\0b", 12), context), "embedded NUL path must fail");
    Check(cfa::WithinRoot(L"C:\\a", L"C:\\"), "drive-root child match");
    Check(!cfa::WithinRoot(L"D:\\a", L"C:\\"), "different drive mismatch");
    Check(ParsePlanOnly(*plan), "system PowerShell parser accepts encoded plan without executing it");
    fake.protected_install = false;
    int prior_writes = fake.write_calls;
    Check(cfa::Run(apply, fake).status == cfa::Status::Failed && fake.write_calls == prior_writes,
          "elevated apply cannot bypass protected-install guard");
    Check(!TrustedSddl(L"O:BAG:BAD:P(A;;0x00000004;;;BU)(A;;FA;;;BA)"), "bundle/ProgramFiles create-child permission rejects writeable branch");
    Check(cfa::ValidateSystemPowerShellReadOnly(native_context), "OS-owned hardlinked PowerShell/modules must validate read-only");
    Check(cfa::CaseInsensitiveDirectory(0), "ordinary Windows directory supports normalized case matching");
    Check(!cfa::CaseInsensitiveDirectory(FILE_CS_FLAG_CASE_SENSITIVE_DIR), "case-sensitive directory cannot use case-insensitive event identity");
    Check(!cfa::CaseInsensitiveDirectory(2), "unknown directory case semantics fail closed");
    std::cout << "PASS " << checks << " checks\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "FAIL after " << checks << " checks: " << e.what() << '\n';
    return 1;
  }
}
