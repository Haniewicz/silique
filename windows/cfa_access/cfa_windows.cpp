#include "cfa_windows.h"
#include <aclapi.h>
#include <shlobj.h>
#include <shellapi.h>
#include <algorithm>

namespace cfa {
namespace {
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  Handle() = default;
  explicit Handle(HANDLE input) : value(input) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value(std::exchange(other.value, INVALID_HANDLE_VALUE)) {}
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) { Handle old(std::exchange(value, std::exchange(other.value, INVALID_HANDLE_VALUE))); }
    return *this;
  }
  explicit operator bool() const { return value && value != INVALID_HANDLE_VALUE; }
};
struct EventHandle {
  EVT_HANDLE value;
  explicit EventHandle(EVT_HANDLE input) : value(input) {}
  ~EventHandle() { if (value) EvtClose(value); }
  EventHandle(const EventHandle&) = delete;
  EventHandle& operator=(const EventHandle&) = delete;
};
std::wstring ModulePath() {
  std::vector<wchar_t> buffer(32768);
  DWORD size = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  return size && size < buffer.size() ? std::wstring(buffer.data(), size) : std::wstring();
}
std::wstring SystemDirectory() {
  std::vector<wchar_t> buffer(32768);
  UINT size = GetSystemDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
  return size && size < buffer.size() ? std::wstring(buffer.data(), size) : std::wstring();
}
std::optional<std::wstring> KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR value = nullptr;
  if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &value))) return std::nullopt;
  std::wstring result(value);
  CoTaskMemFree(value);
  return result;
}
enum class Kind { Any, File, Directory };
struct Pinned { std::wstring path; Handle handle; bool directory; };
class FilePins {
 public:
  explicit FilePins(const PathContext& context) : context_(context) {}
  bool PinPath(const std::wstring& input, Kind kind, bool missing_ok = false, bool require_single_link = true) {
    auto path = NormalizePath(input, context_);
    if (!path || GetDriveTypeW(path->substr(0, 3).c_str()) != DRIVE_FIXED) return false;
    size_t end = 3;
    for (;;) {
      std::wstring part = path->substr(0, end);
      bool last = end == path->size();
      Kind needed = last ? kind : Kind::Directory;
      auto found = std::find_if(files_.begin(), files_.end(), [&](const Pinned& item) { return SamePath(item.path, part); });
      if (found != files_.end()) {
        if ((needed == Kind::Directory && !found->directory) || (needed == Kind::File && found->directory)) return false;
      } else {
        if (files_.size() >= 12000) return false;
        std::wstring extended = L"\\\\?\\" + part;
        Handle file(CreateFileW(extended.c_str(), GENERIC_READ | READ_CONTROL, FILE_SHARE_READ, nullptr,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        if (!file) {
          DWORD error = GetLastError();
          return missing_ok && (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
        }
        BY_HANDLE_FILE_INFORMATION info{};
        if (!GetFileInformationByHandle(file.value, &info) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
        bool directory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (directory) {
          FILE_CASE_SENSITIVE_INFO case_info{};
          if (!GetFileInformationByHandleEx(file.value, FileCaseSensitiveInfo, &case_info, sizeof(case_info)) ||
              !CaseInsensitiveDirectory(case_info.Flags)) return false;
        }
        if ((needed == Kind::Directory && !directory) || (needed == Kind::File && directory) ||
            (!directory && require_single_link && info.nNumberOfLinks != 1)) return false;
        std::vector<wchar_t> final_path(32768);
        DWORD count = GetFinalPathNameByHandleW(file.value, final_path.data(), static_cast<DWORD>(final_path.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (!count || count >= final_path.size()) return false;
        auto final = NormalizePath(std::wstring(final_path.data(), count), context_);
        if (!final || !SamePath(*final, part)) return false;
        files_.push_back({part, std::move(file), directory});
      }
      if (last) return true;
      size_t next = path->find(L'\\', end == 3 ? 3 : end + 1);
      end = next == std::wstring::npos ? path->size() : next;
    }
  }
  bool TrustedPath(const std::wstring& input, bool ancestor_only) const {
    auto found = std::find_if(files_.begin(), files_.end(), [&](const Pinned& item) { return SamePath(item.path, input); });
    if (found == files_.end()) return false;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    DWORD error = GetSecurityInfo(found->handle.value, SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, nullptr, nullptr, nullptr, nullptr, &descriptor);
    if (error != ERROR_SUCCESS || !descriptor) return false;
    bool trusted = TrustedDescriptor(descriptor, ancestor_only);
    LocalFree(descriptor);
    return trusted;
  }
  bool TrustedChain(const std::wstring& path) const {
    for (const auto& file : files_) {
      if (WithinRoot(path, file.path) && !TrustedPath(file.path, !SamePath(path, file.path))) return false;
    }
    return TrustedPath(path, false);
  }
  bool TrustedBranch(const std::wstring& path, const std::wstring& anchor) const {
    for (const auto& file : files_) {
      if (WithinRoot(file.path, anchor) && WithinRoot(path, file.path) && !TrustedPath(file.path, false)) return false;
    }
    return TrustedPath(anchor, false);
  }
  bool TrustedTree(const std::wstring& root, unsigned depth = 0, bool require_single_link = true) {
    if (depth > 64 || !PinPath(root, Kind::Directory) || !TrustedPath(root, false)) return false;
    WIN32_FIND_DATAW data{};
    HANDLE search = FindFirstFileW((L"\\\\?\\" + root + L"\\*").c_str(), &data);
    if (search == INVALID_HANDLE_VALUE) return false;
    bool success = true;
    do {
      std::wstring name(data.cFileName);
      if (name == L"." || name == L"..") continue;
      auto child = root + L"\\" + name;
      if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) { success = false; break; }
      if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) success = TrustedTree(child, depth + 1, require_single_link);
      else success = PinPath(child, Kind::File, false, require_single_link) && TrustedPath(child, false);
      if (!success) break;
    } while (FindNextFileW(search, &data));
    DWORD error = GetLastError();
    FindClose(search);
    return success && error == ERROR_NO_MORE_FILES;
  }
 private:
  PathContext context_;
  std::vector<Pinned> files_;
};
struct Rendered {
  std::vector<EVT_VARIANT> buffer;
  DWORD count = 0;
  bool Read(EVT_HANDLE context, EVT_HANDLE event) {
    DWORD size = 0;
    if (EvtRender(context, event, EvtRenderEventValues, 0, nullptr, &size, &count) ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER || size > 1024 * 1024) return false;
    buffer.resize((size + sizeof(EVT_VARIANT) - 1) / sizeof(EVT_VARIANT));
    DWORD capacity = static_cast<DWORD>(buffer.size() * sizeof(EVT_VARIANT));
    return EvtRender(context, event, EvtRenderEventValues, capacity, buffer.data(), &size, &count) &&
           count <= buffer.size();
  }
};
std::uint64_t Now() {
  FILETIME time{};
  GetSystemTimeAsFileTime(&time);
  return (std::uint64_t(time.dwHighDateTime) << 32) | time.dwLowDateTime;
}
}

namespace {
bool PinSystemPowerShell(FilePins& pins, const std::wstring& system) {
  if (system.empty()) return false;
  auto executable = system + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  auto modules = system + L"\\WindowsPowerShell\\v1.0\\Modules";
  // OS servicing uses hardlinks into WinSxS. All aliases share the same protected
  // descriptor; unlike bundle files these are allowed only after ownership/DACL checks.
  return pins.PinPath(executable, Kind::File, false, false) && pins.TrustedChain(executable) &&
      pins.TrustedTree(modules + L"\\Defender", 0, false) && pins.TrustedTree(modules + L"\\CimCmdlets", 0, false);
}
bool RunPowerShell(const PowerShellPlan& plan, const std::wstring& system) {
  // No inherited user environment: notably no user PSModulePath, PATH, profiles or CWD modules.
  std::wstring environment;
  for (const auto& entry : std::vector<std::wstring>{
      L"PATH=" + system, L"PSModuleAnalysisCachePath=NUL",
      L"PSModulePath=" + system + L"\\WindowsPowerShell\\v1.0\\Modules",
      L"SystemRoot=" + system.substr(0, system.size() - 9),
      L"WINDIR=" + system.substr(0, system.size() - 9)}) {
    environment += entry;
    environment += L'\0';
  }
  environment += L'\0';
  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  Handle null_file(CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  Handle job(CreateJobObjectW(nullptr, nullptr));
  if (!null_file || !job) return false;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) return false;
  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
  std::vector<unsigned char> storage(attribute_size);
  auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size)) return false;
  struct AttributeCleanup { LPPROC_THREAD_ATTRIBUTE_LIST value; ~AttributeCleanup() { DeleteProcThreadAttributeList(value); } } cleanup{attributes};
  HANDLE inherited[] = {null_file.value};
  if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited, sizeof(inherited), nullptr, nullptr)) return false;
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = startup.StartupInfo.hStdOutput = startup.StartupInfo.hStdError = null_file.value;
  startup.lpAttributeList = attributes;
  std::wstring command = L"\"" + plan.executable + L"\" " + plan.arguments;
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(plan.executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | CREATE_SUSPENDED,
      environment.data(), system.c_str(), &startup.StartupInfo, &process)) return false;
  Handle child(process.hProcess), thread(process.hThread);
  if (!AssignProcessToJobObject(job.value, child.value) || ResumeThread(thread.value) == DWORD(-1)) {
    TerminateProcess(child.value, 25);
    WaitForSingleObject(child.value, 10000);
    return false;
  }
  if (WaitForSingleObject(child.value, 60000) != WAIT_OBJECT_0) {
    TerminateJobObject(job.value, 25);
    WaitForSingleObject(child.value, 10000);
    return false;
  }
  DWORD code = 0;
  return GetExitCodeProcess(child.value, &code) && code == kPowerShellVerified;
}
}
struct NativePlatform::State {
  PathContext context = SystemPathContext();
  FilePins pins{context};
  std::wstring self;
  std::wstring target;
  std::wstring bundle;
  std::optional<std::wstring> root;
  bool ready = false;
  bool protected_install = false;
  State() {
    auto module = NormalizePath(ModulePath(), context);
    if (!module) return;
    self = *module;
    auto separator = self.find_last_of(L'\\');
    if (separator == std::wstring::npos) return;
    bundle = self.substr(0, separator);
    target = bundle + L"\\silique.exe";
  }
};
NativePlatform::NativePlatform() : state_(std::make_unique<State>()) {}
NativePlatform::~NativePlatform() = default;
bool NativePlatform::Elevated() {
  HANDLE raw = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) return false;
  Handle token(raw);
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  return GetTokenInformation(token.value, TokenElevation, &elevation, sizeof(elevation), &size) &&
         size == sizeof(elevation) && elevation.TokenIsElevated != 0;
}
bool NativePlatform::Prepare(const std::optional<std::wstring>& root) {
  auto& s = *state_;
  s.ready = s.protected_install = false;
  if (s.self.empty() || s.target.empty() ||
      !SamePath(s.self.substr(s.self.find_last_of(L'\\') + 1), L"silique_folder_access.exe")) return false;
  if (!s.pins.PinPath(s.self, Kind::File) || !s.pins.PinPath(s.target, Kind::File)) return false;
  s.root.reset();
  if (root) {
    s.root = NormalizePath(*root, s.context);
    if (!s.root || !s.pins.PinPath(*s.root, Kind::Directory)) return false;
  }
  s.ready = true;
  return true;
}
bool NativePlatform::ProtectedInstall() {
  auto& s = *state_;
  s.protected_install = false;
  if (!s.ready) return false;
  auto known = KnownFolder(FOLDERID_ProgramFiles); // Native x64 known folder, never an environment variable.
  if (!known) return false;
  auto program_files = NormalizePath(*known, s.context);
  if (!program_files || !WithinRoot(s.bundle, *program_files) || SamePath(s.bundle, *program_files) ||
      !s.pins.PinPath(*program_files, Kind::Directory) || !s.pins.TrustedChain(s.bundle) ||
      !s.pins.TrustedBranch(s.bundle, *program_files) || !s.pins.TrustedTree(s.bundle)) return false;
  s.protected_install = true;
  return true;
}
Evidence NativePlatform::Confirm(const std::optional<std::wstring>& root) {
  return state_->ready ? QueryEvidence(state_->target, root, state_->context) : Evidence::Error;
}
Status NativePlatform::RequestElevation() {
  auto& s = *state_;
  if (!s.ready || !s.protected_install) return Status::Failed;
  auto evidence = QueryEvidence(s.target, s.root, s.context);
  if (evidence != Evidence::Confirmed) return evidence == Evidence::Absent ? Status::Unconfirmed : Status::Failed;
  auto system = SystemDirectory();
  if (system.empty()) return Status::Failed;
  HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  if (FAILED(initialized)) return Status::Failed;
  struct ComCleanup { ~ComCleanup() { CoUninitialize(); } } cleanup;
  SHELLEXECUTEINFOW execute{};
  execute.cbSize = sizeof(execute);
  execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  execute.lpVerb = L"runas";
  execute.lpFile = s.self.c_str();
  execute.lpParameters = L"--apply"; // Deliberately no root/target/command or inherited caller payload.
  execute.lpDirectory = system.c_str();
  execute.nShow = SW_HIDE;
  if (!ShellExecuteExW(&execute)) return MapShellError(GetLastError());
  Handle child(execute.hProcess);
  if (!child || WaitForSingleObject(child.value, INFINITE) != WAIT_OBJECT_0) return Status::Failed;
  DWORD code = 0;
  return GetExitCodeProcess(child.value, &code) ? MapApplyExit(code) : Status::Failed;
}
bool NativePlatform::AddAndVerify() {
  auto& s = *state_;
  if (!Elevated() || !s.ready || !s.protected_install || !ProtectedInstall()) return false;
  auto system = SystemDirectory();
  auto plan = BuildPowerShellPlan(system, s.target, s.context);
  if (!plan || !PinSystemPowerShell(s.pins, system)) return false;
  if (QueryEvidence(s.target, std::nullopt, s.context) != Evidence::Confirmed) return false;
  return RunPowerShell(*plan, system);
}
std::wstring NativePlatform::executable() const { return state_->target; }

PathContext SystemPathContext() {
  PathContext result;
  if (auto profile = KnownFolder(FOLDERID_Profile)) result.profile = *profile;
  for (wchar_t letter = L'A'; letter <= L'Z'; ++letter) {
    std::wstring drive{letter, L':'};
    wchar_t device[32768]{};
    if (QueryDosDeviceW(drive.c_str(), device, 32768)) result.devices.push_back({device, drive});
  }
  return result;
}
bool ValidateSystemPowerShellReadOnly(const PathContext& context) {
  FilePins pins(context);
  return PinSystemPowerShell(pins, SystemDirectory());
}
bool ValidateReadOnlyPath(const std::wstring& path, bool directory, const PathContext& context) {
  FilePins pins(context);
  return pins.PinPath(path, directory ? Kind::Directory : Kind::File);
}
Evidence QueryEvidence(const std::wstring& target, const std::optional<std::wstring>& root,
                       const PathContext& context) {
  auto app = NormalizePath(target, context);
  std::optional<std::wstring> normalized_root;
  if (root) { normalized_root = NormalizePath(*root, context); if (!normalized_root) return Evidence::Error; }
  if (!app) return Evidence::Error;
  EventHandle query(EvtQuery(nullptr, kChannel,
      L"*[System[Provider[@Name='Microsoft-Windows-Windows Defender'] and EventID=1123 and TimeCreated[timediff(@SystemTime) <= 300000]]]",
      EvtQueryChannelPath | EvtQueryReverseDirection));
  if (!query.value) return Evidence::Error;
  EventHandle system(EvtCreateRenderContext(0, nullptr, EvtRenderContextSystem));
  LPCWSTR paths[] = {kDataPaths[0], kDataPaths[1]};
  EventHandle data(EvtCreateRenderContext(2, paths, EvtRenderContextValues));
  if (!system.value || !data.value) return Evidence::Error;
  ULONGLONG deadline = GetTickCount64() + 5000;
  for (unsigned i = 0; i < 1024 && GetTickCount64() < deadline; ++i) {
    EVT_HANDLE raw = nullptr;
    DWORD returned = 0;
    if (!EvtNext(query.value, 1, &raw, 1000, 0, &returned))
      return GetLastError() == ERROR_NO_MORE_ITEMS ? Evidence::Absent : Evidence::Error;
    EventHandle event(raw);
    if (returned != 1 || !event.value) return Evidence::Error;
    Rendered sv, dv;
    if (!sv.Read(system.value, event.value) || !dv.Read(data.value, event.value)) return Evidence::Error;
    auto decoded = DecodeEvent(sv.buffer.data(), sv.count, dv.buffer.data(), dv.count);
    if (!decoded || !MatchesEvent(*decoded, *app, normalized_root, Now(), context)) continue;
    auto blocked = NormalizePath(decoded->path, context);
    FilePins event_pins(context);
    // A blocked create may name a nonexistent file. Every existing ancestor is still checked.
    if (blocked && event_pins.PinPath(*blocked, Kind::Any, true)) return Evidence::Confirmed;
  }
  return Evidence::Error; // Event flood/time budget cannot establish safe absence.
}
}
