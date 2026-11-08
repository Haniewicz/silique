#ifndef SILIQUE_GUARD_PROTOCOL_H_
#define SILIQUE_GUARD_PROTOCOL_H_
#include <windows.h>
#include <string>
namespace silique {
inline constexpr wchar_t kAppMutex[] = L"Global\\Silique.App.1A327809-A7B2-5F2D-B263-D46B18C17B6B";
inline constexpr wchar_t kUpdateGate[] = L"Global\\Silique.Update.1A327809-A7B2-5F2D-B263-D46B18C17B6B";
inline constexpr wchar_t kUninstallKey[] = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{1A327809-A7B2-5F2D-B263-D46B18C17B6B}_is1";
inline constexpr BYTE kGuardHello = 0x53;
inline constexpr BYTE kGuardAcknowledged = 0x41;
inline bool GuardTokenValid(const std::wstring& token) {
  return token.size() == 32 && token.find_first_not_of(L"0123456789abcdef") == std::wstring::npos;
}
inline std::wstring GuardPipeName(const std::wstring& token) {
  return L"\\\\.\\pipe\\Silique.Update." + token;
}
}  // namespace silique
#endif
