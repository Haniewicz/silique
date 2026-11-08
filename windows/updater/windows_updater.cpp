#include "windows_updater.h"
#include "guard_protocol.h"
#include <bcrypt.h>
#include <sddl.h>
#include <aclapi.h>
#include <shlobj.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cwctype>
namespace silique {
namespace {
std::atomic<bool> launching{false};
std::atomic<bool> handed_off{false};
HANDLE application_instance = nullptr; // process lifetime, NOT inherited by guard
bool Rejected(const char* stage) {
  (void)stage;
#ifdef SILIQUE_UPDATER_DIAGNOSTICS
  std::fprintf(stderr, "INSTALL REJECT %s win32=%lu\n", stage, GetLastError());
#endif
  return false;
}
bool Equal(const std::wstring& a, const std::wstring& b) {
  return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
std::wstring TrimSlash(std::wstring path) {
  while (path.size() > 3 && path.back() == L'\\') path.pop_back();
  return path;
}
bool SafePath(const std::wstring& path) {
  if (path.size() < 4 || !iswalpha(path[0]) || path[1] != L':' || path[2] != L'\\' ||
      path.find_first_of(L"/\"\r\n") != std::wstring::npos || path.find(L':', 2) != std::wstring::npos ||
      path.find(L'\0') != std::wstring::npos || path.back() == L'\\') return false;
  size_t start = 3;
  while (start < path.size()) {
    const auto end = path.find(L'\\', start);
    const auto part = path.substr(start, end == std::wstring::npos ? end : end - start);
    if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ') return false;
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  return true;
}
std::wstring FinalPath(HANDLE handle, DWORD flags = VOLUME_NAME_DOS) {
  std::vector<wchar_t> buffer(32768);
  const auto length = GetFinalPathNameByHandleW(handle, buffer.data(), static_cast<DWORD>(buffer.size()), flags);
  return length && length < buffer.size() ? std::wstring(buffer.data(), length) : L"";
}
bool PinDirectory(const std::wstring& path, WindowsUpdateLocks& locks) {
  // FILE_LIST_DIRECTORY participates in share checking. Attribute-only handles
  // do not. No WRITE or DELETE sharing: also reject pre-existing such handles.
  HANDLE handle = CreateFileW(path.c_str(), FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return Rejected("pin-directory-open");
  FILE_ATTRIBUTE_TAG_INFO info{};
  const bool ok = GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &info, sizeof(info)) &&
      (info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      Equal(TrimSlash(FinalPath(handle)), TrimSlash(L"\\\\?\\" + path));
  if (!ok) { Rejected("pin-directory-type-canonical"); CloseHandle(handle); return false; }
  locks.handles.push_back(handle); return true;
}
bool PinParents(const std::wstring& path, WindowsUpdateLocks& locks) {
  if (!SafePath(path) || GetDriveTypeW(path.substr(0, 3).c_str()) != DRIVE_FIXED ||
      !PinDirectory(path.substr(0, 3), locks)) return false;
  size_t at = 3;
  while ((at = path.find(L'\\', at)) != std::wstring::npos) {
    if (!PinDirectory(path.substr(0, at), locks)) return false;
    ++at;
  }
  return true;
}
bool TrustedPrincipal(PSID sid) {
  // Conservative ACL policy: nonstandard write authorities are manual-only.
  // An elevated caller's access check would approve user-writable paths too.
  for (const auto text : {L"S-1-5-18", L"S-1-5-32-544",
      L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"}) {
    PSID trusted = nullptr;
    if (!ConvertStringSidToSidW(text, &trusted)) return false;
    const bool same = EqualSid(sid, trusted) != FALSE; LocalFree(trusted);
    if (same) return true;
  }
  return false;
}
bool ProtectedDirectory(HANDLE directory, bool destination) {
  PSID owner = nullptr; PACL acl = nullptr; PSECURITY_DESCRIPTOR security = nullptr;
  if (GetSecurityInfo(directory, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &acl, nullptr, &security) != ERROR_SUCCESS) return false;
  bool ok = owner && TrustedPrincipal(owner) && acl;
#ifdef SILIQUE_UPDATER_DIAGNOSTICS
  if (!ok) std::fprintf(stderr, "INSTALL ACL initial owner-trusted=%d acl=%d\n", owner && TrustedPrincipal(owner), acl != nullptr);
#endif
  const DWORD dangerous = WRITE_DAC | WRITE_OWNER | DELETE | FILE_DELETE_CHILD |
      FILE_WRITE_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES | (destination ? FILE_APPEND_DATA : 0);
  GENERIC_MAPPING mapping{FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_GENERIC_EXECUTE, FILE_ALL_ACCESS};
  if (ok) for (DWORD i = 0; i < acl->AceCount; ++i) {
    void* raw = nullptr;
    if (!GetAce(acl, i, &raw)) { ok = false; break; }
    const auto header = static_cast<ACE_HEADER*>(raw);
    if (header->AceFlags & INHERIT_ONLY_ACE) continue;
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    // Conditional/object ACEs are not modeled: fail closed rather than guess.
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) { ok = false; break; }
    const auto ace = static_cast<ACCESS_ALLOWED_ACE*>(raw); DWORD mask = ace->Mask;
    MapGenericMask(&mask, &mapping);
    if ((mask & dangerous) && !TrustedPrincipal(reinterpret_cast<PSID>(&ace->SidStart))) {
#ifdef SILIQUE_UPDATER_DIAGNOSTICS
      std::fprintf(stderr, "INSTALL ACL untrusted-write mask=%lu dangerous=%lu\n", mask, mask & dangerous);
#endif
      ok = false; break;
    }
  }
  LocalFree(security); return ok;
}
bool ProtectedInstallTree(const std::wstring& directory, WindowsUpdateLocks& locks) {
  const auto first = locks.handles.size();
  if (!PinParents(directory + L"\\silique.exe", locks)) return false;
  for (size_t i = first; i < locks.handles.size(); ++i)
    if (!ProtectedDirectory(locks.handles[i], i + 1 == locks.handles.size())) {
#ifdef SILIQUE_UPDATER_DIAGNOSTICS
      std::fprintf(stderr, "INSTALL ACL ancestor=%zu of %zu\n", i - first, locks.handles.size() - first);
#endif
      return Rejected("protected-directory");
    }
  return true;
}
HANDLE PinFile(const std::wstring& path, WindowsUpdateLocks& locks) {
  if (!PinParents(path, locks)) return INVALID_HANDLE_VALUE;
  HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return handle;
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(handle, &info) ||
      (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
      info.nNumberOfLinks != 1 || !Equal(FinalPath(handle), L"\\\\?\\" + path)) {
    CloseHandle(handle); return INVALID_HANDLE_VALUE;
  }
  locks.handles.push_back(handle); return handle;
}
std::string Hash(HANDLE file) {
  LARGE_INTEGER zero{};
  if (!SetFilePointerEx(file, zero, nullptr, FILE_BEGIN)) return {};
  BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return {};
  if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
    BCryptCloseAlgorithmProvider(algorithm, 0); return {};
  }
  std::array<UCHAR, 65536> buffer{}; DWORD read = 0; bool ok = true;
  for (;;) {
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) { ok = false; break; }
    if (!read) break;
    if (BCryptHashData(hash, buffer.data(), read, 0) < 0) { ok = false; break; }
  }
  std::array<UCHAR, 32> digest{};
  if (ok) ok = BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
  BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return {};
  const char hex[] = "0123456789abcdef"; std::string result;
  for (auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}
std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR value = nullptr;
  if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &value))) return {};
  std::wstring result(value); CoTaskMemFree(value); return TrimSlash(result);
}
std::wstring RandomToken() {
  std::array<UCHAR, 16> random{};
  if (BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return {};
  const wchar_t hex[] = L"0123456789abcdef"; std::wstring result;
  for (auto byte : random) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}
PSECURITY_DESCRIPTOR UserDescriptor(bool pipe) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return nullptr;
  DWORD length = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  std::vector<BYTE> user(length);
  const bool got = GetTokenInformation(token, TokenUser, user.data(), length, &length) != FALSE;
  CloseHandle(token); LPWSTR sid = nullptr;
  if (!got || !ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid, &sid)) return nullptr;
  const std::wstring sddl = pipe ? L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;" + std::wstring(sid) + L")" :
      L"D:P(A;OICI;FA;;;SY)(A;OICI;GRGX;;;BA)(A;OICI;FA;;;" + std::wstring(sid) + L")";
  LocalFree(sid); PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return nullptr;
  return descriptor;
}
std::wstring RegistryText(HKEY key, const wchar_t* name) {
  std::vector<wchar_t> value(32768); DWORD bytes = static_cast<DWORD>(value.size() * sizeof(wchar_t)), type = 0;
  if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(value.data()), &bytes) != ERROR_SUCCESS ||
      type != REG_SZ || bytes < sizeof(wchar_t) || bytes > value.size() * sizeof(wchar_t) ||
      bytes % sizeof(wchar_t) || value[bytes / sizeof(wchar_t) - 1] != L'\0') return {};
  const std::wstring text(value.data());
  return (text.size() + 1) * sizeof(wchar_t) == bytes ? text : L"";
}
bool ReadVersion(const std::wstring& path, std::string* version, int* build) {
  DWORD ignored = 0; const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
  if (!size || size > 1024 * 1024) return false;
  std::vector<BYTE> buffer(size);
  if (!GetFileVersionInfoW(path.c_str(), 0, size, buffer.data())) return false;
  VS_FIXEDFILEINFO* info = nullptr; UINT length = 0;
  if (!VerQueryValueW(buffer.data(), L"\\", reinterpret_cast<void**>(&info), &length) ||
      length < sizeof(VS_FIXEDFILEINFO) || info->dwSignature != 0xfeef04bd) return false;
  *version = std::to_string(HIWORD(info->dwFileVersionMS)) + "." + std::to_string(LOWORD(info->dwFileVersionMS)) +
      "." + std::to_string(HIWORD(info->dwFileVersionLS));
  *build = LOWORD(info->dwFileVersionLS); return true;
}
bool SingleRunningModule(const std::wstring& module) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry); unsigned count = 0; bool ok = true;
  if (!Process32FirstW(snapshot, &entry)) ok = false;
  else do {
    if (!Equal(entry.szExeFile, L"silique.exe")) continue;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
    std::vector<wchar_t> path(32768); DWORD length = static_cast<DWORD>(path.size());
    if (!p || !QueryFullProcessImageNameW(p, 0, path.data(), &length)) ok = false;
    else if (Equal(std::wstring(path.data(), length), module)) ++count;
    if (p) CloseHandle(p);
  } while (Process32NextW(snapshot, &entry));
  CloseHandle(snapshot); return ok && count == 1;
}
}  // namespace
WindowsUpdateLocks::~WindowsUpdateLocks() { for (auto handle : handles) CloseHandle(handle); }
WindowsUpdateGuard::~WindowsUpdateGuard() { if (process) CloseHandle(process); if (cancel) CloseHandle(cancel); }
void WindowsUpdateGuard::CancelBeforeLaunch() { SetEvent(cancel); WaitForSingleObject(process, INFINITE); }
std::wstring WindowsModulePath() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  return !length || length >= path.size() ? L"" : std::wstring(path.data(), length);
}
bool WindowsUpdateBlocksClose() { return false; } // guard is ready BEFORE any elevation
bool WindowsInstallIdentityMatches(const std::wstring& module, const std::wstring& registered,
    const std::wstring& program_files) {
  return SafePath(module) && SafePath(TrimSlash(registered)) && SafePath(TrimSlash(program_files)) &&
      Equal(module, TrimSlash(registered) + L"\\silique.exe");
}
std::wstring WindowsInstalledDirectory(const std::wstring& module) {
  // No caller-supplied module can lend an installed identity to a portable EXE.
  if (!Equal(module, WindowsModulePath())) { Rejected("module"); return {}; }
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kUninstallKey, 0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) { Rejected("registration"); return {}; }
  const auto registered = RegistryText(key, L"InstallLocation");
  const auto display_version = RegistryText(key, L"DisplayVersion");
  const auto uninstall = RegistryText(key, L"UninstallString"); RegCloseKey(key);
  if (!WindowsInstallIdentityMatches(module, registered, KnownFolder(FOLDERID_ProgramFiles))) { Rejected("identity-path"); return {}; }
  const auto dir = TrimSlash(registered);
  if (!Equal(uninstall, L"\"" + dir + L"\\unins000.exe\"")) { Rejected("uninstaller-registration"); return {}; }
  WindowsUpdateLocks locks;
  if (!ProtectedInstallTree(dir, locks)) { Rejected("install-tree"); return {}; }
  const auto registered_directory = FinalPath(locks.handles.back());
  const auto image = PinFile(module, locks);
  const auto uninstaller = PinFile(dir + L"\\unins000.exe", locks);
  if (image == INVALID_HANDLE_VALUE || uninstaller == INVALID_HANDLE_VALUE ||
      !ProtectedDirectory(image, true) || !ProtectedDirectory(uninstaller, true)) { Rejected("installed-files"); return {}; }
  const auto canonical_image = FinalPath(image);
  const auto separator = canonical_image.find_last_of(L'\\');
  // Compare resolved spellings exactly as well as Win32 text. Case-sensitive
  // NTFS directories can contain distinct names that compare equal ignoring
  // case; the registration must not lend another directory our loaded image.
  if (separator == std::wstring::npos || canonical_image.substr(0, separator) != registered_directory) { Rejected("canonical-directory"); return {}; }
  // Compare the actual loaded mapping too, not just GetModuleFileName text.
  std::vector<wchar_t> mapped(32768);
  const auto length = GetMappedFileNameW(GetCurrentProcess(), GetModuleHandleW(nullptr), mapped.data(), static_cast<DWORD>(mapped.size()));
  if (!length || length >= mapped.size() || std::wstring(mapped.data(), length) != FinalPath(image, VOLUME_NAME_NT)) { Rejected("loaded-image"); return {}; }
  std::string version; int build = 0;
  if (!ReadVersion(module, &version, &build) || !Equal(display_version, std::wstring(version.begin(), version.end()))) { Rejected("display-version"); return {}; }
  return dir;
}
bool AcquireWindowsApplicationInstance() {
  if (application_instance) return true;
  // All supported running copies participate before Dart/SQLite/key access.
  HANDLE gate = OpenMutexW(SYNCHRONIZE, FALSE, kUpdateGate);
  if (gate) { CloseHandle(gate); return false; }
  if (GetLastError() != ERROR_FILE_NOT_FOUND) return false;
  auto descriptor = UserDescriptor(true); if (!descriptor) return false;
  SECURITY_ATTRIBUTES sa{sizeof(sa), descriptor, FALSE};
  HANDLE instance = CreateMutexW(&sa, FALSE, kAppMutex); const auto error = GetLastError(); LocalFree(descriptor);
  if (!instance || error == ERROR_ALREADY_EXISTS) { if (instance) CloseHandle(instance); return false; }
  // Recheck gate after winning the instance race.
  gate = OpenMutexW(SYNCHRONIZE, FALSE, kUpdateGate);
  if (gate || GetLastError() != ERROR_FILE_NOT_FOUND) { if (gate) CloseHandle(gate); CloseHandle(instance); return false; }
  application_instance = instance; return true;
}
std::wstring CreatePrivateUpdateDirectory() {
  const auto base = KnownFolder(FOLDERID_LocalAppData); WindowsUpdateLocks parents;
  if (!PinParents(base + L"\\placeholder", parents)) return {};
  auto descriptor = UserDescriptor(false); if (!descriptor) return {};
  SECURITY_ATTRIBUTES sa{sizeof(sa), descriptor, FALSE}; const auto token = RandomToken();
  const auto path = token.empty() ? L"" : base + L"\\silique-updates-" + token;
  const bool ok = !path.empty() && CreateDirectoryW(path.c_str(), &sa); LocalFree(descriptor);
  return ok ? path : L"";
}
std::unique_ptr<WindowsUpdateLocks> LockWindowsArtifact(const std::wstring& path, const std::string& sha256, int64_t size) {
  if (size < 1 || size > 512LL * 1024 * 1024 || sha256.size() != 64 ||
      sha256.find_first_not_of("0123456789abcdef") != std::string::npos) return nullptr;
  auto locks = std::make_unique<WindowsUpdateLocks>(); const auto file = PinFile(path, *locks); LARGE_INTEGER length{};
  if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &length) || length.QuadPart != size || Hash(file) != sha256) return nullptr;
  return locks;
}
std::unique_ptr<WindowsUpdateGuard> StartWindowsUpdateGuard(const std::wstring& guard,
    WindowsUpdateLocks& locks, HANDLE parent) {
  auto result = std::make_unique<WindowsUpdateGuard>(); result->token = RandomToken();
  if (result->token.empty()) return nullptr;
  auto descriptor = UserDescriptor(true); if (!descriptor) return nullptr;
  SECURITY_ATTRIBUTES sa{sizeof(sa), descriptor, TRUE};
  HANDLE pipe = CreateNamedPipeW(GuardPipeName(result->token).c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 16, 16, 0, &sa);
  LocalFree(descriptor); if (pipe == INVALID_HANDLE_VALUE) return nullptr;
  // Event ACL need not be public: these are unnamed, explicitly inherited only.
  SECURITY_ATTRIBUTES inherited_sa{sizeof(inherited_sa), nullptr, TRUE};
  result->cancel = CreateEventW(&inherited_sa, TRUE, FALSE, nullptr);
  HANDLE ready = CreateEventW(&inherited_sa, TRUE, FALSE, nullptr), parent_copy = nullptr;
  if (!result->cancel || !ready || !DuplicateHandle(GetCurrentProcess(), parent, GetCurrentProcess(), &parent_copy,
      SYNCHRONIZE, TRUE, 0)) { if (ready) CloseHandle(ready); CloseHandle(pipe); return nullptr; }
  std::vector<HANDLE> inherited{pipe, result->cancel, ready, parent_copy};
  inherited.insert(inherited.end(), locks.handles.begin(), locks.handles.end());
  bool ok = true;
  for (const auto handle : inherited) if (!SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) ok = false;
  SIZE_T size = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<BYTE> attributes(size); auto list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  const bool initialized = InitializeProcThreadAttributeList(list, 1, 0, &size) != FALSE;
  ok = ok && initialized;
  if (ok) ok = UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited.data(), inherited.size() * sizeof(HANDLE), nullptr, nullptr) != FALSE;
  std::wstring command = L"\"" + guard + L"\"";
  for (const auto handle : inherited) command += L" " + std::to_wstring(reinterpret_cast<uintptr_t>(handle));
  STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = list; PROCESS_INFORMATION child{};
  // An over-the-shoulder UAC administrator may duplicate a SYNCHRONIZE handle
  // of Inno itself into the guard. No need for a low user to open an admin's
  // process, and no reliance on the loader's hProcess or an asserted PID.
  auto process_descriptor = UserDescriptor(true);
  SECURITY_ATTRIBUTES process_sa{sizeof(process_sa), process_descriptor, FALSE};
  if (!process_descriptor) ok = false;
  if (ok) ok = CreateProcessW(guard.c_str(), command.data(), &process_sa, nullptr, TRUE,
      CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr, &startup.StartupInfo, &child) != FALSE;
  if (process_descriptor) LocalFree(process_descriptor);
  for (const auto handle : inherited) SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0);
  if (initialized) DeleteProcThreadAttributeList(list);
  if (ok) {
    result->process = child.hProcess; CloseHandle(child.hThread);
    HANDLE wait[]{ready, child.hProcess}; ok = WaitForMultipleObjects(2, wait, FALSE, 10000) == WAIT_OBJECT_0;
    if (!ok) result->CancelBeforeLaunch();
  }
  CloseHandle(ready); CloseHandle(parent_copy); CloseHandle(pipe);
  return ok ? std::move(result) : nullptr;
}
bool WindowsUpdater::installed() const {
  std::string actual; int build = 0;
  if (WindowsInstalledDirectory(WindowsModulePath()).empty()) return false;
  const bool ok = ReadVersion(WindowsModulePath(), &actual, &build) && actual == version_ && build == build_;
#ifdef SILIQUE_UPDATER_DIAGNOSTICS
  if (!ok) std::fprintf(stderr, "INSTALL VERSION actual=%s/%d expected=%s/%d\n", actual.c_str(), build, version_.c_str(), build_);
#endif
  return ok;
}
std::wstring WindowsUpdater::directory() {
  if (directory_.empty() && installed()) directory_ = CreatePrivateUpdateDirectory();
  return directory_;
}
std::string WindowsUpdater::install(HWND window, const std::wstring& path, const std::string& version,
    int build, const std::string& hash, int64_t size) {
  if (handed_off.load() || launching.exchange(true)) return "failed";
  struct Reset { ~Reset() { launching.store(false); } } reset;
  const auto module = WindowsModulePath(); const auto install_dir = WindowsInstalledDirectory(module);
  if (!application_instance || !installed() || install_dir.empty() || directory_.empty() ||
      build <= build_ || build > 65535 || !Equal(path, directory_ + L"\\Silique-" + std::to_wstring(build) + L".exe")) return "failed";
  unsigned a = 0, b = 0, c = 0, x = 0, y = 0, z = 0; int used = 0;
  if (sscanf_s(version.c_str(), "%u.%u.%u%n", &a, &b, &c, &used) != 3 || used != static_cast<int>(version.size()) ||
      a > 65535 || b > 65535 || c > 65535 ||
      sscanf_s(version_.c_str(), "%u.%u.%u", &x, &y, &z) != 3 || std::array<unsigned,3>{a,b,c} < std::array<unsigned,3>{x,y,z}) return "failed";
  auto locks = LockWindowsArtifact(path, hash, size); if (!locks) return "failed";
  std::string artifact_version; int artifact_build = 0;
  if (!ReadVersion(path, &artifact_version, &artifact_build) || artifact_version != version || artifact_build != build) return "failed";
  // Pin an image section as well: do not accept an already mapped writable EXE.
  HANDLE image = CreateFileMappingW(locks->handles.back(), nullptr, PAGE_READONLY | SEC_IMAGE_NO_EXECUTE, 0, 0, nullptr);
  if (!image) return "failed";
  locks->handles.push_back(image);
  // Hash again after establishing the section barrier; never execute the image.
  // The original file remains the preceding handle, all the way through Setup.
  if (Hash(locks->handles[locks->handles.size() - 2]) != hash) return "failed";
  // Destination pins protect pre-launch verification/UAC, not consumption.
  // Transferring them to the guard prevents Inno renaming destination files.
  // Only trusted administrators can mutate this validated ACL-protected tree;
  // the guard waits for this process to exit before acknowledging Setup, so
  // these local pins are gone before replacement. Artifact pins stay inherited.
  WindowsUpdateLocks destination;
  if (!ProtectedInstallTree(install_dir, destination)) return "failed";
  auto descriptor = UserDescriptor(true); if (!descriptor) return "failed";
  SECURITY_ATTRIBUTES sa{sizeof(sa), descriptor, FALSE};
  HANDLE gate = CreateMutexW(&sa, FALSE, kUpdateGate); const auto error = GetLastError(); LocalFree(descriptor);
  if (!gate || error == ERROR_ALREADY_EXISTS) { if (gate) CloseHandle(gate); return "failed"; }
  locks->handles.push_back(gate);
  if (!SingleRunningModule(module)) return "failed";
  const auto source = install_dir + L"\\silique_update_guard.exe", guard = directory_ + L"\\guard.exe";
  WindowsUpdateLocks trusted; const auto original = PinFile(source, trusted);
  if (original == INVALID_HANDLE_VALUE || !ProtectedDirectory(original, true)) return "failed";
  if (!CopyFileW(source.c_str(), guard.c_str(), TRUE) && GetLastError() != ERROR_FILE_EXISTS) return "failed";
  const auto copy = PinFile(guard, *locks);
  const auto guard_hash = Hash(original);
  if (copy == INVALID_HANDLE_VALUE || guard_hash.empty() || guard_hash != Hash(copy)) return "failed";
  // The copied guard is executable too. A file pin alone cannot exclude a
  // writable mapping whose file handle has closed. Retain the section through
  // guard startup/handoff, and rehash only after establishing that barrier.
  HANDLE guard_image = CreateFileMappingW(copy, nullptr, PAGE_READONLY | SEC_IMAGE_NO_EXECUTE, 0, 0, nullptr);
  if (!guard_image) return "failed";
  locks->handles.push_back(guard_image);
  if (Hash(copy) != guard_hash) return "failed";
  if (before_guard_start_) before_guard_start_();
  auto held = StartWindowsUpdateGuard(guard, *locks, GetCurrentProcess());
  if (!held) return "failed"; // no Setup has been started on any failure above
  const std::wstring arguments = L"/SILIQUEUPDATE=1 /SILIQUEGUARD=" + held->token +
      L" /SILIQUEGUARDPID=" + std::to_wstring(GetProcessId(held->process)) +
      L" /NORESTART /NOCLOSEAPPLICATIONS /DIR=\"" + install_dir + L"\"";
  SHELLEXECUTEINFOW launch{}; launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC; launch.hwnd = window;
  launch.lpVerb = L"runas"; launch.lpFile = path.c_str(); launch.lpParameters = arguments.c_str();
  launch.lpDirectory = directory_.c_str(); launch.nShow = SW_SHOWNORMAL;
  if (!launch_(&launch)) {
    const auto failure = GetLastError(); held->CancelBeforeLaunch();
    return failure == ERROR_CANCELLED ? "cancelled" : "failed";
  }
  // Successful launch is irrevocable. Bootstrap handles do NOT establish Inno's
  // consumption lifetime. Guard retains locks until authenticated Setup exits;
  // absence of handshake/unknown lifetime means retaining them indefinitely.
  if (launch.hProcess) CloseHandle(launch.hProcess);
  handed_off.store(true); return "launched";
}
}  // namespace silique
