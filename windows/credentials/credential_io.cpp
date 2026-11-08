#include "credential_io.h"
extern "C" HANDLE SiliqueCredentialOpen(const wchar_t* name, DWORD access,
    DWORD share, SECURITY_ATTRIBUTES* security, DWORD creation, DWORD flags,
    HANDLE template_file, DWORD* error) {
  const auto result = CreateFileW(name, access, share, security, creation, flags, template_file);
  *error = result == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  return result;
}
extern "C" BOOL SiliqueCredentialMkdir(const wchar_t* name,
    SECURITY_ATTRIBUTES* security, DWORD* error) {
  const auto result = CreateDirectoryW(name, security);
  *error = result ? ERROR_SUCCESS : GetLastError();
  return result;
}
extern "C" BOOL SiliqueCredentialLock(HANDLE file, DWORD flags,
    DWORD reserved, DWORD low, DWORD high, OVERLAPPED* overlapped, DWORD* error) {
  const auto result = LockFileEx(file, flags, reserved, low, high, overlapped);
  *error = result ? ERROR_SUCCESS : GetLastError();
  return result;
}
