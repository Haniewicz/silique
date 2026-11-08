#include "credential_io.h"
#include <cstdio>
#include <string>
#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "FAIL credential IO line %d error=%lu\n", __LINE__, error); return 86; } } while (false)
int wmain() {
  DWORD error = 0;
  wchar_t temp[MAX_PATH], unique[MAX_PATH];
  CHECK(GetTempPathW(MAX_PATH, temp));
  CHECK(GetTempFileNameW(temp, L"sci", 0, unique));
  CHECK(DeleteFileW(unique));
  const std::wstring root(unique), file = root + L"\\absent";
  CHECK(SiliqueCredentialMkdir(root.c_str(), nullptr, &error));
  CHECK(error == ERROR_SUCCESS);
  CHECK(!SiliqueCredentialMkdir(root.c_str(), nullptr, &error));
  SetLastError(ERROR_SUCCESS);
  CHECK(error == ERROR_ALREADY_EXISTS);
  for (int i = 0; i < 1000; ++i) {
    const auto missing = SiliqueCredentialOpen(file.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr, &error);
    SetLastError(ERROR_SUCCESS); // model VM/allocator TLS clobber after FFI
    CHECK(missing == INVALID_HANDLE_VALUE && error == ERROR_FILE_NOT_FOUND);
  }
  HANDLE first = SiliqueCredentialOpen(file.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_NEW, 0, nullptr, &error);
  CHECK(first != INVALID_HANDLE_VALUE && error == ERROR_SUCCESS);
  HANDLE second = SiliqueCredentialOpen(file.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr, &error);
  CHECK(second != INVALID_HANDLE_VALUE);
  OVERLAPPED one{}, two{};
  CHECK(SiliqueCredentialLock(first, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &one, &error));
  CHECK(!SiliqueCredentialLock(second, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &two, &error));
  SetLastError(ERROR_SUCCESS);
  CHECK(error == ERROR_LOCK_VIOLATION);
  CHECK(CloseHandle(first));
  CHECK(SiliqueCredentialLock(second, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &two, &error));
  CHECK(error == ERROR_SUCCESS && CloseHandle(second));
  CHECK(DeleteFileW(file.c_str()) && RemoveDirectoryW(root.c_str()));
  std::puts("PASS atomic credential missing-file/mkdir/lock errors survive TLS clobber and retry");
  return 0;
}
