#include "flutter_window.h"
#include "native_language.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>

namespace {
bool ReadInterfaceLanguage() {
  // Match path_provider_windows: RoamingAppData / CompanyName / ProductName
  // from Runner.rc. Read only, bounded, and never initialize storage or create
  // directories before the application/update gate. Failure defaults to English.
  PWSTR roaming = nullptr;
  const HRESULT status = SHGetKnownFolderPath(
      FOLDERID_RoamingAppData, KF_FLAG_DONT_VERIFY, nullptr, &roaming);
  if (FAILED(status) || !roaming) {
    CoTaskMemFree(roaming);
    return false;
  }
  const std::wstring path = std::wstring(roaming) + L"\\Silique\\silique\\interface-language";
  CoTaskMemFree(roaming);
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info{};
  char bytes[16]{};
  DWORD count = 0;
  const bool read = GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
      info.nFileSizeHigh == 0 && info.nFileSizeLow < sizeof(bytes) &&
      ReadFile(file, bytes, static_cast<DWORD>(sizeof(bytes)), &count, nullptr);
  CloseHandle(file);
  return read && silique::IsPolishInterfaceLanguage(std::string_view(bytes, count));
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  if (size) WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  if (size) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}
const flutter::EncodableValue* Field(const flutter::EncodableMap& map, const char* name) {
  const auto it = map.find(flutter::EncodableValue(name));
  return it == map.end() ? nullptr : &it->second;
}
std::string Text(const flutter::EncodableMap& map, const char* name) {
  const auto value = Field(map, name);
  const auto text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : "";
}
int64_t Integer(const flutter::EncodableMap& map, const char* name) {
  const auto value = Field(map, name);
  if (!value) return -1;
  if (const auto number = std::get_if<int32_t>(value)) return *number;
  if (const auto number = std::get_if<int64_t>(value)) return *number;
  return -1;
}
}  // namespace

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // Before Flutter, notebook initialization, DPAPI or any mutation. The guard
  // keeps the update gate alive after this process exits; Setup never kills us.
  if (!silique::AcquireWindowsApplicationInstance()) {
    MessageBoxW(nullptr,
        silique::WindowsInstanceMessage(ReadInterfaceLanguage()),
        L"Silique", MB_OK | MB_ICONINFORMATION);
    return false;
  }
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  updates_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "silique.notes/updates",
      &flutter::StandardMethodCodec::GetInstance());
  updates_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableValue;
    if (call.method_name() == "info") {
      result->Success(EncodableValue(flutter::EncodableMap{
        {EncodableValue("version"), EncodableValue(SILIQUE_UPDATE_VERSION)},
        {EncodableValue("build"), EncodableValue(static_cast<int32_t>(FLUTTER_VERSION_BUILD))},
        {EncodableValue("platform"), EncodableValue(windows_updater_.installed() ? "windows" : "windows-portable")},
      }));
    } else if (call.method_name() == "downloadDirectory") {
      const auto directory = windows_updater_.directory();
      if (directory.empty()) result->Error("update_directory", silique::WindowsUpdateDirectoryMessage(ReadInterfaceLanguage()));
      else result->Success(EncodableValue(Utf8(directory)));
    } else if (call.method_name() == "installWindows") {
      const auto args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      const auto build = args ? Integer(*args, "build") : -1;
      if (!args || build < 1 || build > 65535) { result->Success(EncodableValue("failed")); return; }
      result->Success(EncodableValue(windows_updater_.install(GetHandle(), Wide(Text(*args, "path")),
        Text(*args, "version"), static_cast<int>(build), Text(*args, "sha256"), Integer(*args, "size"))));
    } else result->NotImplemented();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  updates_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if ((message == WM_CLOSE || message == WM_QUERYENDSESSION) && silique::WindowsUpdateBlocksClose()) return 0;
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // Controller reset can synchronously reenter the parent window handler.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
