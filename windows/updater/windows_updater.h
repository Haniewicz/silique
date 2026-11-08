#ifndef SILIQUE_WINDOWS_UPDATER_H_
#define SILIQUE_WINDOWS_UPDATER_H_
#include <windows.h>
#include <shellapi.h>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>
namespace silique {
class WindowsUpdateLocks {
 public:
  ~WindowsUpdateLocks();
  std::vector<HANDLE> handles;
};
struct WindowsUpdateGuard {
  ~WindowsUpdateGuard();
  // Only call when ShellExecute returned FALSE, i.e. Setup was NOT launched.
  void CancelBeforeLaunch();
  HANDLE process = nullptr;
  HANDLE cancel = nullptr;
  std::wstring token;
};
std::unique_ptr<WindowsUpdateLocks> LockWindowsArtifact(const std::wstring& path,
    const std::string& sha256, int64_t size);
std::unique_ptr<WindowsUpdateGuard> StartWindowsUpdateGuard(const std::wstring& guard,
    WindowsUpdateLocks& locks, HANDLE parent);
std::wstring CreatePrivateUpdateDirectory();
bool WindowsInstallIdentityMatches(const std::wstring& module,
    const std::wstring& registered, const std::wstring& program_files);
std::wstring WindowsInstalledDirectory(const std::wstring& module);
std::wstring WindowsModulePath();
bool AcquireWindowsApplicationInstance();
bool WindowsUpdateBlocksClose();
class WindowsUpdater {
 public:
  WindowsUpdater(std::string version, int build) : version_(version), build_(build) {}
  bool installed() const;
  std::wstring directory();
  std::string install(HWND window, const std::wstring& path, const std::string& version,
      int build, const std::string& hash, int64_t size);
  // Test transport is never exposed through the Flutter method channel.
  void SetLaunchForTest(std::function<BOOL(SHELLEXECUTEINFOW*)> launch) { launch_ = std::move(launch); }
  // Deterministic race probe at the executable guard-copy boundary.
  void SetBeforeGuardStartForTest(std::function<void()> callback) { before_guard_start_ = std::move(callback); }
 private:
  std::string version_;
  int build_;
  std::function<BOOL(SHELLEXECUTEINFOW*)> launch_ = ShellExecuteExW;
  std::function<void()> before_guard_start_;
  std::wstring directory_;
};
}  // namespace silique
#endif
