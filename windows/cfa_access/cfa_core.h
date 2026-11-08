#pragma once
#include <windows.h>
#include <winevt.h>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace cfa {
struct PathContext {
  std::wstring profile;
  std::vector<std::pair<std::wstring, std::wstring>> devices;
};
std::optional<std::wstring> NormalizePath(const std::wstring& input, const PathContext& context);
bool SamePath(const std::wstring& a, const std::wstring& b);
bool WithinRoot(const std::wstring& path, const std::wstring& root);
bool CaseInsensitiveDirectory(DWORD case_flags);
inline constexpr std::uint64_t kFreshTicks = 300ULL * 10000000ULL;
inline constexpr wchar_t kProvider[] = L"Microsoft-Windows-Windows Defender";
inline constexpr wchar_t kChannel[] = L"Microsoft-Windows-Windows Defender/Operational";
inline constexpr const wchar_t* kDataPaths[] = {
    L"Event/EventData/Data[@Name='Process Name']", L"Event/EventData/Data[@Name='Path']"};
struct Event { std::wstring executable; std::wstring path; std::uint64_t time; };
enum class Mode { Invalid, Inspect, Request, Apply };
struct Arguments { Mode mode = Mode::Invalid; std::optional<std::wstring> root; };
Arguments ParseArguments(const std::vector<std::wstring>& arguments);
enum class Status { Confirmed, Unconfirmed, Allowed, Cancelled, Failed };
enum class Evidence { Confirmed, Absent, Error };
inline constexpr DWORD kApplyAllowed = 0x534901;
inline constexpr DWORD kApplyUnconfirmed = 0x534902;
inline constexpr DWORD kApplyFailed = 0x534903;
inline constexpr DWORD kPowerShellVerified = 21;
Status MapApplyExit(DWORD exit_code);
Status MapShellError(DWORD error);
struct Platform {
  virtual ~Platform() = default;
  virtual bool Elevated() = 0;
  virtual bool Prepare(const std::optional<std::wstring>& root) = 0;
  virtual bool ProtectedInstall() = 0;  // Entire bundle, trusted ownership/DACLs.
  virtual Evidence Confirm(const std::optional<std::wstring>& root) = 0;
  virtual Status RequestElevation() = 0;  // Fixed --apply only, no caller data.
  virtual bool AddAndVerify() = 0;        // Self-derived sibling only.
};
struct Result { Status status; const char* message; bool can_request = false; };
Result Run(const Arguments& arguments, Platform& platform);
std::string Json(const Result& result, const std::wstring& executable);
bool TrustedDescriptor(PSECURITY_DESCRIPTOR descriptor, bool ancestor_only = false);
struct PowerShellPlan { std::wstring executable; std::wstring arguments; std::wstring script; };
std::optional<PowerShellPlan> BuildPowerShellPlan(const std::wstring& system_directory,
    const std::wstring& target, const PathContext& context);

std::optional<Event> DecodeEvent(const EVT_VARIANT* system, size_t system_count,
                                 const EVT_VARIANT* data, size_t data_count);
bool MatchesEvent(const Event& event, const std::wstring& target,
                  const std::optional<std::wstring>& root, std::uint64_t now,
                  const PathContext& context);
}
