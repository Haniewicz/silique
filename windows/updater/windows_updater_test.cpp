// Win32 tests. Full acceptance requires a clean disposable native Windows CI
// machine. Focused subset flags under Wine are diagnostics, never acceptance.
#include "windows_updater.h"
#include "guard_protocol.h"
#include <windows.h>
#include <winioctl.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <cstddef>
#include <cstring>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <fstream>
#include <iostream>
#include <string>
// Deterministic noninteractive failure, including MSVC Release builds. No CRT
// assertion dialog may turn a negative-control failure into a CI timeout.
#undef assert
#define assert(expression) do { if (!(expression)) { std::cerr << "FAIL line " << __LINE__ << ": " << #expression << std::endl; ExitProcess(86); } } while (false)
using namespace silique;
namespace {
constexpr char kAbcHash[] = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
std::string Ascii(const wchar_t* text) {
  std::string result;
  for (; *text; ++text) {
    assert(*text <= 0x7f);
    result.push_back(static_cast<char>(*text));
  }
  return result;
}
void Write(const std::wstring& path) { std::ofstream out(path.c_str(), std::ios::binary); out << "abc"; }
HANDLE OpenDirectory(const std::wstring& path, DWORD access) {
  return CreateFileW(path.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
}
void Barriers(const std::wstring& file, const std::wstring& parent, const std::wstring& ancestor) {
  HANDLE writer = CreateFileW(file.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, 0, nullptr);
  assert(writer == INVALID_HANDLE_VALUE);
  assert(!DeleteFileW(file.c_str()));
  assert(!MoveFileExW(file.c_str(), (file + L".renamed").c_str(), MOVEFILE_REPLACE_EXISTING));
  for (const auto& dir : {parent, ancestor}) {
    assert(!MoveFileExW(dir.c_str(), (dir + L".renamed").c_str(), 0));
    assert(!RemoveDirectoryW(dir.c_str()));
    const auto h = OpenDirectory(dir, GENERIC_WRITE);
    assert(h == INVALID_HANDLE_VALUE); // includes FSCTL_SET_REPARSE_POINT access
    const auto d = OpenDirectory(dir, DELETE);
    assert(d == INVALID_HANDLE_VALUE);
  }
}
void Junction(const std::wstring& link, const std::wstring& root) {
  assert(CreateDirectoryW(link.c_str(), nullptr));
  const auto target = L"\\??\\" + root;
  struct MountPoint { DWORD tag; WORD length, reserved; WORD so, sl, po, pl; wchar_t paths[32768]; } data{};
  data.tag = IO_REPARSE_TAG_MOUNT_POINT;
  data.sl = static_cast<WORD>(target.size() * sizeof(wchar_t));
  data.po = static_cast<WORD>(data.sl + sizeof(wchar_t));
  data.pl = static_cast<WORD>(root.size() * sizeof(wchar_t));
  std::memcpy(data.paths, target.c_str(), data.sl);
  std::memcpy(reinterpret_cast<BYTE*>(data.paths) + data.po, root.c_str(), data.pl);
  data.length = static_cast<WORD>(8 + data.po + data.pl + sizeof(wchar_t));
  const HANDLE h = OpenDirectory(link, GENERIC_WRITE);
  assert(h != INVALID_HANDLE_VALUE);
  DWORD returned = 0;
  assert(DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, &data,
      static_cast<DWORD>(offsetof(MountPoint, paths) + data.po + data.pl + sizeof(wchar_t)),
      nullptr, 0, &returned, nullptr));
  CloseHandle(h);
}
void FileTests(bool barriers_only = false) {
  const auto root = CreatePrivateUpdateDirectory(); assert(!root.empty());
  const auto parent = root + L"\\Zażółć gęślą jaźń spaces";
  assert(CreateDirectoryW(parent.c_str(), nullptr));
  const auto file = parent + L"\\Setup Unicode ą.exe";
  Write(file);
  assert(!LockWindowsArtifact(file, kAbcHash, 4));
  assert(!LockWindowsArtifact(file, std::string(64, 'a'), 3));
  HANDLE writer = CreateFileW(file.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, 0, nullptr);
  assert(writer != INVALID_HANDLE_VALUE);
  assert(!LockWindowsArtifact(file, kAbcHash, 3)); CloseHandle(writer);
  // Regression: reject already-open writable AND delete-capable ancestors.
  for (const auto& dir : {parent, root}) for (DWORD access : {GENERIC_WRITE, DELETE}) {
    const auto h = OpenDirectory(dir, access); assert(h != INVALID_HANDLE_VALUE);
    assert(!LockWindowsArtifact(file, kAbcHash, 3)); CloseHandle(h);
  }
  auto locked = LockWindowsArtifact(file, kAbcHash, 3); assert(locked);
  Barriers(file, parent, root); locked.reset();
  if (barriers_only) {
    assert(DeleteFileW(file.c_str())); assert(RemoveDirectoryW(parent.c_str())); assert(RemoveDirectoryW(root.c_str()));
    std::cout << "PASS file/ancestor barriers (subset; no reparse or native Windows acceptance)\n";
    return;
  }
  const auto link = root + L"\\junction";
  Junction(link, parent);
  assert(!LockWindowsArtifact(link + L"\\Setup Unicode ą.exe", kAbcHash, 3));
  assert(RemoveDirectoryW(link.c_str()));
  const auto hardlink = parent + L"\\alias.exe";
  assert(CreateHardLinkW(hardlink.c_str(), file.c_str(), nullptr));
  assert(!LockWindowsArtifact(file, kAbcHash, 3));
  assert(DeleteFileW(hardlink.c_str()));
  assert(DeleteFileW(file.c_str())); assert(RemoveDirectoryW(parent.c_str())); assert(RemoveDirectoryW(root.c_str()));
  std::cout << "PASS native byte locks, pre-open writers/deleters, all-ancestor namespace, Unicode, junction/hardlink\n";
}
HANDLE EventArg(const wchar_t* arg) { return reinterpret_cast<HANDLE>(static_cast<uintptr_t>(_wcstoui64(arg, nullptr, 10))); }
PROCESS_INFORMATION Spawn(const std::wstring& args, bool inherit = true) {
  const auto self = WindowsModulePath(); auto command = L"\"" + self + L"\" " + args;
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION child{};
  assert(CreateProcessW(self.c_str(), command.data(), nullptr, nullptr, inherit, CREATE_NO_WINDOW,
      nullptr, nullptr, &startup, &child)); CloseHandle(child.hThread); return child;
}
void GuardTests(const std::wstring& guard) {
  const auto root = CreatePrivateUpdateDirectory(); assert(!root.empty());
  const auto parent = root + L"\\Ścieżka with spaces"; assert(CreateDirectoryW(parent.c_str(), nullptr));
  const auto file = parent + L"\\setup.exe"; Write(file);
  auto locks = LockWindowsArtifact(file, kAbcHash, 3); assert(locks);
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  HANDLE leave = CreateEventW(&sa, TRUE, FALSE, nullptr);
  HANDLE acknowledged = CreateEventW(&sa, TRUE, FALSE, nullptr);
  HANDLE finish = CreateEventW(&sa, TRUE, FALSE, nullptr);
  assert(leave && acknowledged && finish);
  auto parent_child = Spawn(L"--wait " + std::to_wstring(reinterpret_cast<uintptr_t>(leave)));
  HANDLE gate = CreateMutexW(nullptr, FALSE, kUpdateGate); assert(gate && GetLastError() != ERROR_ALREADY_EXISTS);
  locks->handles.push_back(gate);
  auto held = StartWindowsUpdateGuard(guard, *locks, parent_child.hProcess); assert(held);
  locks.reset();
  auto blocked_instance = Spawn(L"--instance no");
  assert(WaitForSingleObject(blocked_instance.hProcess, 30000) == WAIT_OBJECT_0);
  DWORD instance_code = 1;
  assert(GetExitCodeProcess(blocked_instance.hProcess, &instance_code) && instance_code == 0);
  CloseHandle(blocked_instance.hProcess);
  // Unrelated bootstrap termination must never release the guard.
  auto bootstrap = Spawn(L"--exit"); assert(WaitForSingleObject(bootstrap.hProcess, 30000) == WAIT_OBJECT_0);
  CloseHandle(bootstrap.hProcess); Barriers(file, parent, root);
  auto consumer = Spawn(L"--consumer " + held->token + L" " + std::to_wstring(GetProcessId(held->process)) +
      L" " + std::to_wstring(reinterpret_cast<uintptr_t>(acknowledged)) +
      L" " + std::to_wstring(reinterpret_cast<uintptr_t>(finish)));
  Barriers(file, parent, root);
  SetEvent(leave); assert(WaitForSingleObject(parent_child.hProcess, 30000) == WAIT_OBJECT_0);
  // Consumer stays alive after reading guard ACK: locks must survive parent exit.
  assert(WaitForSingleObject(acknowledged, 30000) == WAIT_OBJECT_0);
  assert(WaitForSingleObject(consumer.hProcess, 0) == WAIT_TIMEOUT);
  Barriers(file, parent, root);
  assert(SetEvent(finish));
  assert(WaitForSingleObject(consumer.hProcess, 30000) == WAIT_OBJECT_0);
  DWORD code = 1; assert(GetExitCodeProcess(consumer.hProcess, &code) && code == 0);
  assert(WaitForSingleObject(held->process, 30000) == WAIT_OBJECT_0);
  CloseHandle(parent_child.hProcess); CloseHandle(consumer.hProcess); CloseHandle(leave);
  CloseHandle(acknowledged); CloseHandle(finish);
  assert(DeleteFileW(file.c_str())); assert(RemoveDirectoryW(parent.c_str())); assert(RemoveDirectoryW(root.c_str()));
  std::cout << "PASS Win32 guard outlives bootstrap/app and retains locks through actual high-integrity consumer lifetime\n";
}
void GuardFailureTests(const std::wstring& guard) {
  const auto root = CreatePrivateUpdateDirectory(); assert(!root.empty());
  const auto file = root + L"\\guard-failure.exe"; Write(file);
  for (const auto invalid_peer : {false, true}) {
    auto locks = LockWindowsArtifact(file, kAbcHash, 3); assert(locks);
    auto held = StartWindowsUpdateGuard(guard, *locks, GetCurrentProcess()); assert(held);
    locks.reset();
    if (invalid_peer) {
      auto peer = Spawn(L"--invalid-consumer " + held->token);
      assert(WaitForSingleObject(peer.hProcess, 30000) == WAIT_OBJECT_0);
      DWORD code = 1; assert(GetExitCodeProcess(peer.hProcess, &code) && code == 0);
      CloseHandle(peer.hProcess);
      assert(WaitForSingleObject(held->process, 200) == WAIT_TIMEOUT);
    }
    // UAC/launch rejection is the ONLY pre-launch release path. No peer or an
    // invalid/disconnected peer must never acknowledge lifetime consumption.
    Barriers(file, root, root);
    held->CancelBeforeLaunch();
    HANDLE writable = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    assert(writable != INVALID_HANDLE_VALUE); CloseHandle(writable);
  }
  assert(DeleteFileW(file.c_str())); assert(RemoveDirectoryW(root.c_str()));
  std::cout << "PASS guard cancellation and fail-closed invalid consumer\n";
}
}  // namespace
int wmain(int argc, wchar_t** argv) {
  if (argc == 3 && std::wstring(argv[1]) == L"--guard-tests") { GuardTests(argv[2]); GuardFailureTests(argv[2]); return 0; }
  if (argc == 2 && std::wstring(argv[1]) == L"--identity-path-tests") {
    assert(WindowsInstallIdentityMatches(L"D:\\Protected Apps\\Silique ą\\silique.exe", L"D:\\Protected Apps\\Silique ą", L"C:\\Program Files"));
    assert(!WindowsInstallIdentityMatches(L"D:\\Protected Apps\\Other\\silique.exe", L"D:\\Protected Apps\\Silique ą", L"C:\\Program Files"));
    assert(!WindowsInstallIdentityMatches(L"C:\\Apps\\..\\Silique\\silique.exe", L"C:\\Apps\\..\\Silique", L"C:\\Program Files"));
    assert(!WindowsInstallIdentityMatches(L"C:\\Apps.\\Silique\\silique.exe", L"C:\\Apps.\\Silique", L"C:\\Program Files"));
    std::cout << "PASS exact custom install identity paths\n"; return 0;
  }
  if (argc == 2 && std::wstring(argv[1]) == L"--barrier-tests") { FileTests(true); return 0; }
  if (argc == 2 && std::wstring(argv[1]) == L"--file-tests") { FileTests(); return 0; }
  if (argc == 3 && std::wstring(argv[1]) == L"--instance") {
    assert(AcquireWindowsApplicationInstance() == (std::wstring(argv[2]) == L"yes")); return 0;
  }
  if (argc == 2 && std::wstring(argv[1]) == L"--exit") return 0;
  if (argc == 3 && std::wstring(argv[1]) == L"--wait") return WaitForSingleObject(EventArg(argv[2]), 60000) == WAIT_OBJECT_0 ? 0 : 2;
  if (argc == 3 && std::wstring(argv[1]) == L"--invalid-consumer") {
    HANDLE pipe = CreateFileW(GuardPipeName(argv[2]).c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    assert(pipe != INVALID_HANDLE_VALUE);
    BYTE hello = kGuardHello; DWORD invalid = 0, bytes = 0;
    assert(WriteFile(pipe, &hello, 1, &bytes, nullptr) && bytes == 1);
    assert(WriteFile(pipe, &invalid, sizeof(invalid), &bytes, nullptr) && bytes == sizeof(invalid));
    CloseHandle(pipe); return 0;
  }
  if (argc == 6 && std::wstring(argv[1]) == L"--consumer") {
    const auto pipe_name = GuardPipeName(argv[2]);
    HANDLE pipe = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return 3;
    HANDLE server = OpenProcess(PROCESS_DUP_HANDLE, FALSE, static_cast<DWORD>(_wcstoui64(argv[3], nullptr, 10)));
    if (!server) return 5;
    HANDLE remote = nullptr;
    const BOOL duplicated = DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), server, &remote,
        SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, 0);
    CloseHandle(server); if (!duplicated) return 6;
    const DWORD remote_value = static_cast<DWORD>(reinterpret_cast<uintptr_t>(remote));
    BYTE hello = kGuardHello, ack = 0; DWORD bytes = 0;
    if (!WriteFile(pipe, &hello, 1, &bytes, nullptr) || bytes != 1 ||
        !WriteFile(pipe, &remote_value, sizeof(remote_value), &bytes, nullptr) || bytes != sizeof(remote_value) ||
        !ReadFile(pipe, &ack, 1, &bytes, nullptr) || bytes != 1 || ack != kGuardAcknowledged) return 4;
    CloseHandle(pipe); // disconnect is NOT process completion
    if (!SetEvent(EventArg(argv[4]))) return 7;
    return WaitForSingleObject(EventArg(argv[5]), 30000) == WAIT_OBJECT_0 ? 0 : 8;
  }
  if (argc == 5 && std::wstring(argv[1]) == L"--identity") {
    const auto version = Ascii(argv[2]);
    const bool expected = std::wstring(argv[4]) == L"yes";
    assert(WindowsUpdater(version, _wtoi(argv[3])).installed() == expected);
    return 0;
  }
  if (argc == 8 && std::wstring(argv[1]) == L"--handoff") {
    const auto version = Ascii(argv[3]), hash = Ascii(argv[5]);
    const int build = _wtoi(argv[4]); const auto size = _wcstoi64(argv[6], nullptr, 10);
    WindowsUpdater updater(version, build);
    assert(updater.installed());
    assert(AcquireWindowsApplicationInstance());
    const auto root = updater.directory(); assert(!root.empty());
    const auto path = root + L"\\Silique-" + std::to_wstring(build + 1) + L".exe";
    assert(CopyFileW(argv[2], path.c_str(), TRUE));
    bool called = false;
    updater.SetLaunchForTest([&](SHELLEXECUTEINFOW* request) -> BOOL {
      called = true;
      assert(std::wstring(request->lpVerb) == L"runas");
      assert(std::wstring(request->lpParameters).find(L"SILENT") == std::wstring::npos);
      Barriers(path, root, root); // BEFORE UAC, while the callback is entered
      SetLastError(ERROR_CANCELLED); return FALSE;
    });
    assert(updater.install(nullptr, path, version, build + 1, std::string(64, 'a'), size) == "failed");
    assert(!called);
    // Previously mapped writable bytes remain writable after their file HANDLE
    // closes. A share-only lock is insufficient: image-section acquisition must
    // reject this condition before any elevation request.
    HANDLE writable = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    assert(writable != INVALID_HANDLE_VALUE);
    HANDLE mapping = CreateFileMappingW(writable, nullptr, PAGE_READWRITE, 0, 0, nullptr);
    assert(mapping); auto view = MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, 0); assert(view);
    CloseHandle(writable);
    assert(updater.install(nullptr, path, version, build + 1, hash, size) == "failed");
    assert(!called); UnmapViewOfFile(view); CloseHandle(mapping);
    // The guard copy is independently executable, and an existing copy is
    // accepted. Keep a writable view alive after closing its file handle:
    // the install must fail BEFORE spawning that guard or requesting elevation.
    const auto guard_copy = root + L"\\guard.exe";
    const auto installed_guard = WindowsInstalledDirectory(WindowsModulePath()) + L"\\silique_update_guard.exe";
    assert(CopyFileW(installed_guard.c_str(), guard_copy.c_str(), TRUE));
    writable = CreateFileW(guard_copy.c_str(), GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    assert(writable != INVALID_HANDLE_VALUE);
    mapping = CreateFileMappingW(writable, nullptr, PAGE_READWRITE, 0, 0, nullptr);
    assert(mapping); view = MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, 0); assert(view);
    CloseHandle(writable);
    bool guard_start_called = false;
    updater.SetBeforeGuardStartForTest([&] {
      guard_start_called = true;
      // Remove the data section before CreateProcess can impose its own image
      // lock. Without our earlier boundary, these changed bytes would execute.
      static_cast<BYTE*>(view)[64] ^= 1; // DOS stub only; still a valid guard PE
      assert(FlushViewOfFile(view, 0));
      assert(UnmapViewOfFile(view)); assert(CloseHandle(mapping));
      view = nullptr; mapping = nullptr;
    });
    assert(updater.install(nullptr, path, version, build + 1, hash, size) == "failed");
    assert(!guard_start_called && !called);
    updater.SetBeforeGuardStartForTest({});
    if (view) assert(UnmapViewOfFile(view));
    if (mapping) assert(CloseHandle(mapping));
    assert(DeleteFileW(guard_copy.c_str()));
    assert(updater.install(nullptr, path, version, build + 1, hash, size) == "cancelled");
    assert(called); called = false;
    HANDLE gate_after_cancel = OpenMutexW(SYNCHRONIZE, FALSE, kUpdateGate);
    assert(!gate_after_cancel && GetLastError() == ERROR_FILE_NOT_FOUND);
    HANDLE writable_after_cancel = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    assert(writable_after_cancel != INVALID_HANDLE_VALUE); CloseHandle(writable_after_cancel);
    // A legacy second process bypassing the new instance gate still blocks us.
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE leave = CreateEventW(&sa, TRUE, FALSE, nullptr);
    auto second = Spawn(L"--wait " + std::to_wstring(reinterpret_cast<uintptr_t>(leave)));
    assert(updater.install(nullptr, path, version, build + 1, hash, size) == "failed");
    assert(!called); SetEvent(leave); assert(WaitForSingleObject(second.hProcess, 30000) == WAIT_OBJECT_0);
    CloseHandle(second.hProcess); CloseHandle(leave);
    // Explicit CI transport runs already elevated, not a UAC acceptance claim.
    updater.SetLaunchForTest([&](SHELLEXECUTEINFOW* request) -> BOOL {
      auto command = L"\"" + std::wstring(request->lpFile) + L"\" " + request->lpParameters +
          L" /VERYSILENT /SUPPRESSMSGBOXES /SILIQUEACCEPTANCE=" + argv[7] +
          L" /LOG=\"" + argv[2] + L".log\"";
      STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION child{};
      const BOOL ok = CreateProcessW(request->lpFile, command.data(), nullptr, nullptr, FALSE, 0,
          nullptr, nullptr, &startup, &child);
      if (ok) { CloseHandle(child.hThread); CloseHandle(child.hProcess); request->hProcess = nullptr; }
      return ok; // prove NULL/bootstrap hProcess never means failed after launch
    });
    assert(updater.install(nullptr, path, version, build + 1, hash, size) == "launched");
    const int utf8_size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        path.data(), static_cast<int>(path.size()), nullptr, 0, nullptr, nullptr);
    assert(utf8_size > 0); std::string utf8(static_cast<size_t>(utf8_size), '\0');
    assert(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(), static_cast<int>(path.size()),
        utf8.data(), utf8_size, nullptr, nullptr) == utf8_size);
    std::cout << utf8 << std::endl;
    return 0; // real EXE/module is released, independent guard must retain barriers
  }
  assert(argc == 2);
  FileTests(); GuardTests(argv[1]); GuardFailureTests(argv[1]);
  assert(!WindowsInstallIdentityMatches(L"C:\\Program Files\\Silique copy\\silique.exe", L"C:\\Program Files\\Silique", L"C:\\Program Files"));
  assert(!WindowsInstallIdentityMatches(L"C:\\portable\\silique.exe", L"C:\\Program Files\\Silique", L"C:\\Program Files"));
  assert(!WindowsUpdater("0.0.0", 1).installed());
  return 0;
}
