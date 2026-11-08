#include "cfa_windows.h"
#include <iostream>

int wmain(int argc, wchar_t** argv) {
  cfa::Mode mode = cfa::Mode::Invalid;
  std::wstring executable;
  try {
    std::vector<std::wstring> arguments;
    for (int i = 1; i < argc; ++i) arguments.emplace_back(argv[i]);
    auto parsed = cfa::ParseArguments(arguments);
    mode = parsed.mode;
    // Restrict dynamic resolution before Shell/known-folder code can load anything.
    // Link-time SYSTEM32 dependency flags also cover static imports before main.
    if (!SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32) || !SetDllDirectoryW(L"")) {
      std::cout << cfa::Json({cfa::Status::Failed, "Cannot restrict DLL search; no change was made."}, executable);
      return mode == cfa::Mode::Apply ? static_cast<int>(cfa::kApplyFailed) : 1;
    }
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    cfa::NativePlatform platform;
    executable = platform.executable();
    auto result = cfa::Run(parsed, platform);
    std::cout << cfa::Json(result, executable);
    if (mode == cfa::Mode::Apply) {
      if (result.status == cfa::Status::Allowed) return static_cast<int>(cfa::kApplyAllowed);
      if (result.status == cfa::Status::Unconfirmed) return static_cast<int>(cfa::kApplyUnconfirmed);
      return static_cast<int>(cfa::kApplyFailed);
    }
    return result.status == cfa::Status::Failed ? 1 : 0;
  } catch (...) {
    std::cout << cfa::Json({cfa::Status::Failed, "The helper could not safely complete the operation; access was not confirmed."}, executable);
    return mode == cfa::Mode::Apply ? static_cast<int>(cfa::kApplyFailed) : 1;
  }
}
