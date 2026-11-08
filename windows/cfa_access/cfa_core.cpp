#include "cfa_core.h"
#include <algorithm>
#include <climits>

namespace cfa {
namespace {
bool Equal(const std::wstring& a, const std::wstring& b) {
  if (a.size() > INT_MAX || b.size() > INT_MAX) return false;
  return CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(),
                             static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}
bool Starts(const std::wstring& value, const std::wstring& prefix) {
  return value.size() >= prefix.size() && Equal(value.substr(0, prefix.size()), prefix);
}
}

std::optional<std::wstring> NormalizePath(const std::wstring& input, const PathContext& context) {
  if (input.empty() || input.size() > 32700) return std::nullopt;
  std::wstring path = input;
  std::replace(path.begin(), path.end(), L'/', L'\\');
  const std::wstring profileToken = L"%USERPROFILE%";
  if (Starts(path, profileToken)) {
    if (path.size() > profileToken.size() && path[profileToken.size()] != L'\\') return std::nullopt;
    if (context.profile.empty() || context.profile.find(L'%') != std::wstring::npos) return std::nullopt;
    path = context.profile + path.substr(profileToken.size());
  }
  if (Starts(path, L"\\Device\\")) {
    std::optional<std::wstring> mapped;
    for (const auto& device : context.devices) {
      if (Starts(path, device.first + L"\\")) {
        if (mapped) return std::nullopt;
        mapped = device.second + path.substr(device.first.size());
      }
    }
    if (!mapped) return std::nullopt;
    path = *mapped;
  } else if (Starts(path, L"\\\\?\\")) {
    path.erase(0, 4);
  } else if (Starts(path, L"\\??\\")) {
    path.erase(0, 4);
  }
  if (path.size() < 3 || !((path[0] >= L'A' && path[0] <= L'Z') ||
      (path[0] >= L'a' && path[0] <= L'z')) || path[1] != L':' || path[2] != L'\\') return std::nullopt;
  for (size_t i = 0; i < path.size(); ++i) {
    wchar_t ch = path[i];
    if (ch >= 0xd800 && ch <= 0xdbff &&
        (i + 1 >= path.size() || path[i + 1] < 0xdc00 || path[i + 1] > 0xdfff)) return std::nullopt;
    if (ch >= 0xdc00 && ch <= 0xdfff &&
        (i == 0 || path[i - 1] < 0xd800 || path[i - 1] > 0xdbff)) return std::nullopt;
    if (ch < 32 || ch == 127 || (ch == L':' && i != 1) ||
        std::wstring(L"<>\"|?*[]%").find(ch) != std::wstring::npos) return std::nullopt;
  }
  while (path.size() > 3 && path.back() == L'\\') path.pop_back();
  size_t begin = 3;
  while (begin < path.size()) {
    size_t end = path.find(L'\\', begin);
    if (end == std::wstring::npos) end = path.size();
    auto part = path.substr(begin, end - begin);
    if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ') return std::nullopt;
    auto stem = part.substr(0, part.find(L'.'));
    if (Equal(stem, L"CON") || Equal(stem, L"PRN") || Equal(stem, L"AUX") || Equal(stem, L"NUL") ||
        Equal(stem, L"CONIN$") || Equal(stem, L"CONOUT$") ||
        (stem.size() == 4 && (Starts(stem, L"COM") || Starts(stem, L"LPT")) &&
         ((stem[3] >= L'1' && stem[3] <= L'9') || stem[3] == L'\x00b9' || stem[3] == L'\x00b2' || stem[3] == L'\x00b3'))) return std::nullopt;
    begin = end + 1;
  }
  return path;
}

namespace {
bool PrivilegedSid(PSID sid) {
  if (!sid || !IsValidSid(sid)) return false;
  if (IsWellKnownSid(sid, WinLocalSystemSid) || IsWellKnownSid(sid, WinBuiltinAdministratorsSid)) return true;
  // NT SERVICE\\TrustedInstaller, not an arbitrary owner or service account.
  const DWORD installer[] = {80, 956008885, 3418522649, 1831038044, 1853292631, 2271478464};
  const SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
  if (*GetSidSubAuthorityCount(sid) != 6 || memcmp(GetSidIdentifierAuthority(sid), &nt, sizeof(nt)) != 0) return false;
  for (DWORD i = 0; i < 6; ++i) if (*GetSidSubAuthority(sid, i) != installer[i]) return false;
  return true;
}
}
bool TrustedDescriptor(PSECURITY_DESCRIPTOR descriptor, bool ancestor_only) {
  if (!descriptor || !IsValidSecurityDescriptor(descriptor)) return false;
  PSID owner = nullptr;
  BOOL defaulted = FALSE, present = FALSE;
  PACL acl = nullptr;
  if (!GetSecurityDescriptorOwner(descriptor, &owner, &defaulted) || !PrivilegedSid(owner) ||
      !GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) || !present || !acl || !IsValidAcl(acl)) return false;
  const DWORD mask = ancestor_only ?
      (DELETE | WRITE_DAC | WRITE_OWNER | FILE_DELETE_CHILD | FILE_WRITE_ATTRIBUTES | GENERIC_WRITE | GENERIC_ALL | MAXIMUM_ALLOWED) :
      (DELETE | WRITE_DAC | WRITE_OWNER | FILE_DELETE_CHILD | FILE_WRITE_DATA | FILE_APPEND_DATA |
       FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES | GENERIC_WRITE | GENERIC_ALL | MAXIMUM_ALLOWED);
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    void* raw = nullptr;
    if (!GetAce(acl, i, &raw)) return false;
    auto header = static_cast<ACE_HEADER*>(raw);
    if (header->AceFlags & ~VALID_INHERIT_FLAGS) return false;
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue; // Never rely on a deny to excuse a dangerous allow.
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) return false; // Callback/object/unknown grants fail closed.
    if (header->AceFlags & INHERIT_ONLY_ACE) continue;
    auto ace = static_cast<ACCESS_ALLOWED_ACE*>(raw);
    if (header->AceSize < offsetof(ACCESS_ALLOWED_ACE, SidStart) + 8) return false;
    PSID sid = &ace->SidStart;
    if (header->AceSize < offsetof(ACCESS_ALLOWED_ACE, SidStart) + 8 + 4 * *GetSidSubAuthorityCount(sid) || !IsValidSid(sid)) return false;
    if ((ace->Mask & mask) != 0 && !PrivilegedSid(sid)) return false;
  }
  return true;
}
namespace {
std::wstring Base64Utf16(const std::wstring& text) {
  static_assert(sizeof(wchar_t) == 2, "Windows UTF-16 required");
  const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const auto* bytes = reinterpret_cast<const unsigned char*>(text.data());
  const size_t size = text.size() * sizeof(wchar_t);
  std::wstring output;
  for (size_t i = 0; i < size; i += 3) {
    unsigned value = unsigned(bytes[i]) << 16;
    if (i + 1 < size) value |= unsigned(bytes[i + 1]) << 8;
    if (i + 2 < size) value |= unsigned(bytes[i + 2]);
    output += alphabet[(value >> 18) & 63];
    output += alphabet[(value >> 12) & 63];
    output += i + 1 < size ? alphabet[(value >> 6) & 63] : L'=';
    output += i + 2 < size ? alphabet[value & 63] : L'=';
  }
  return output;
}
std::wstring DataExpression(const std::wstring& text) {
  return L"([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + Base64Utf16(text) + L"')))";
}
}
std::optional<PowerShellPlan> BuildPowerShellPlan(const std::wstring& system_directory,
    const std::wstring& target, const PathContext& context) {
  auto system = NormalizePath(system_directory, context);
  auto app = NormalizePath(target, context);
  if (!system || !app || !SamePath(*system, system_directory) || !SamePath(*app, target) ||
      system->size() < 9 || !SamePath(system->substr(system->size() - 9), L"\\System32") ||
      app->size() < 12 || !SamePath(app->substr(app->size() - 12), L"\\silique.exe")) return std::nullopt;
  const auto modules = *system + L"\\WindowsPowerShell\\v1.0\\Modules";
  std::wstring script = L"$ErrorActionPreference='Stop';$PSModuleAutoLoadingPreference='None';"
      L"try{$env:PSModulePath=" + DataExpression(modules) + L";"
      L"Import-Module -Name " + DataExpression(modules + L"\\CimCmdlets\\CimCmdlets.psd1") + L" -ErrorAction Stop;"
      L"Import-Module -Name " + DataExpression(modules + L"\\Defender\\Defender.psd1") + L" -ErrorAction Stop;"
      L"$target=" + DataExpression(*app) + L";"
      L"if([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($target) -or $target.Contains('%')){exit 22};"
      L"$null=Defender\\Add-MpPreference -ControlledFolderAccessAllowedApplications @($target) -ErrorAction Stop;"
      L"$p=Defender\\Get-MpPreference -ErrorAction Stop;"
      L"if($null -eq $p -or @($p).Count -ne 1 -or $null -eq $p.PSObject.Properties['ControlledFolderAccessAllowedApplications']){exit 23};"
      L"$found=$false;foreach($entry in @($p.ControlledFolderAccessAllowedApplications)){"
      L"if($entry -is [string] -and [string]::Equals($entry,$target,[StringComparison]::OrdinalIgnoreCase)){$found=$true}};"
      L"if(-not $found){exit 23};exit 21}catch{exit 24}";
  auto arguments = L"-NoLogo -NoProfile -NonInteractive -EncodedCommand " + Base64Utf16(script);
  if (arguments.size() > 30000) return std::nullopt;
  return PowerShellPlan{*system + L"\\WindowsPowerShell\\v1.0\\powershell.exe", arguments, script};
}

Arguments ParseArguments(const std::vector<std::wstring>& arguments) {
  if (arguments.size() == 1 && arguments[0] == L"--apply") return {Mode::Apply, std::nullopt};
  if (arguments.size() != 2 || arguments[1].empty()) return {};
  if (arguments[0] == L"--inspect") return {Mode::Inspect, arguments[1]};
  if (arguments[0] == L"--request") return {Mode::Request, arguments[1]};
  return {};
}
Status MapApplyExit(DWORD code) {
  if (code == kApplyAllowed) return Status::Allowed;
  if (code == kApplyUnconfirmed) return Status::Unconfirmed;
  return Status::Failed;
}
Status MapShellError(DWORD error) { return error == ERROR_CANCELLED ? Status::Cancelled : Status::Failed; }
Result Run(const Arguments& arguments, Platform& platform) {
  if (arguments.mode == Mode::Invalid ||
      (arguments.mode == Mode::Apply && arguments.root) ||
      (arguments.mode != Mode::Apply && !arguments.root))
    return {Status::Failed, "Invalid arguments; no change was made."};
  if (arguments.mode == Mode::Apply && !platform.Elevated())
    return {Status::Failed, "The internal apply mode requires elevation; no change was made."};
  if (!platform.Prepare(arguments.root))
    return {Status::Failed, "Cannot safely validate and pin the application, helper or root; no change was made."};
  if (arguments.mode != Mode::Inspect && !platform.ProtectedInstall())
    return {Status::Failed, "Automatic access requires a protected Program Files installation of the entire Silique bundle; no change was made."};
  auto evidence = platform.Confirm(arguments.root);
  if (evidence == Evidence::Error)
    return {Status::Failed, "Cannot safely read or validate Defender event evidence; no change was made."};
  if (evidence != Evidence::Confirmed)
    return {Status::Unconfirmed, "No fresh matching Defender block event 1123 was confirmed; no change was made."};
  if (arguments.mode == Mode::Inspect)
    return {Status::Confirmed, "A matching Defender block event 1123 from the last five minutes was confirmed.",
            platform.ProtectedInstall()};
  if (arguments.mode == Mode::Request) {
    auto status = platform.RequestElevation();
    switch (status) {
      case Status::Allowed: return {status, "The exact Silique executable was added and verified in Defender preferences."};
      case Status::Cancelled: return {status, "The UAC request was cancelled; no change was requested."};
      case Status::Unconfirmed: return {status, "The elevated helper could not reconfirm a fresh matching block; no change was made."};
      default: return {Status::Failed, "The elevated operation did not verify the exact allow-list entry; access was not confirmed."};
    }
  }
  if (!platform.AddAndVerify())
    return {Status::Failed, "Defender policy update or exact readback failed; access was not confirmed."};
  return {Status::Allowed, "The exact Silique executable was added and verified in Defender preferences."};
}
namespace {
std::string Escape(const std::string& text) {
  std::string result;
  const char hex[] = "0123456789abcdef";
  for (unsigned char ch : text) {
    if (ch == '\\' || ch == '"') { result += '\\'; result += static_cast<char>(ch); }
    else if (ch < 32) { result += "\\u00"; result += hex[ch >> 4]; result += hex[ch & 15]; }
    else result += static_cast<char>(ch);
  }
  return result;
}
}
std::string Json(const Result& result, const std::wstring& executable) {
  std::string path;
  if (!executable.empty()) {
    int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, executable.data(),
        static_cast<int>(executable.size()), nullptr, 0, nullptr, nullptr);
    if (!count) return "{\"status\":\"failed\",\"executable\":\"\",\"message\":\"Invalid executable encoding.\"}\n";
    path.resize(count);
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, executable.data(),
        static_cast<int>(executable.size()), path.data(), count, nullptr, nullptr);
  }
  const char* name = "failed";
  switch (result.status) {
    case Status::Confirmed: name = "confirmed"; break;
    case Status::Unconfirmed: name = "unconfirmed"; break;
    case Status::Allowed: name = "allowed"; break;
    case Status::Cancelled: name = "cancelled"; break;
    case Status::Failed: break;
  }
  return std::string("{\"status\":\"") + name + "\",\"executable\":\"" + Escape(path) +
      "\",\"message\":\"" + Escape(result.message ? result.message : "") +
      "\",\"canRequest\":" + (result.status == Status::Confirmed && result.can_request ? "true" : "false") + "}\n";
}

std::optional<Event> DecodeEvent(const EVT_VARIANT* system, size_t system_count,
                                 const EVT_VARIANT* data, size_t data_count) {
  if (!system || !data || system_count != EvtSystemPropertyIdEND || data_count != 2) return std::nullopt;
  const auto& provider = system[EvtSystemProviderName];
  const auto& channel = system[EvtSystemChannel];
  const auto& id = system[EvtSystemEventID];
  const auto& time = system[EvtSystemTimeCreated];
  const auto& qualifiers = system[EvtSystemQualifiers];
  if (provider.Type != EvtVarTypeString || !provider.StringVal ||
      std::wstring(provider.StringVal) != kProvider ||
      channel.Type != EvtVarTypeString || !channel.StringVal ||
      std::wstring(channel.StringVal) != kChannel || id.Type != EvtVarTypeUInt16 || id.UInt16Val != 1123 ||
      time.Type != EvtVarTypeFileTime || time.FileTimeVal == 0 ||
      (qualifiers.Type != EvtVarTypeNull && (qualifiers.Type != EvtVarTypeUInt16 || qualifiers.UInt16Val != 0)) ||
      data[0].Type != EvtVarTypeString || !data[0].StringVal ||
      data[1].Type != EvtVarTypeString || !data[1].StringVal) return std::nullopt;
  return Event{data[0].StringVal, data[1].StringVal, time.FileTimeVal};
}
bool MatchesEvent(const Event& event, const std::wstring& target,
                  const std::optional<std::wstring>& root, std::uint64_t now,
                  const PathContext& context) {
  if (event.time == 0 || event.time > now || now - event.time > kFreshTicks) return false;
  auto executable = NormalizePath(event.executable, context);
  auto path = NormalizePath(event.path, context);
  if (!executable || !path || !SamePath(*executable, target)) return false;
  return !root || WithinRoot(*path, *root);
}

bool CaseInsensitiveDirectory(DWORD flags) { return flags == 0; }

bool SamePath(const std::wstring& a, const std::wstring& b) { return Equal(a, b); }
bool WithinRoot(const std::wstring& path, const std::wstring& root) {
  if (Equal(path, root)) return true;
  auto prefix = root;
  if (prefix.empty()) return false;
  if (prefix.back() != L'\\') prefix += L'\\';
  return Starts(path, prefix);
}
}
