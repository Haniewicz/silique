"""Compile production Windows runner code against lifecycle-only portable facades.

These model COM/resource ordering and synchronous child teardown reentry, not
real Flutter/Win32 teardown; the Windows natural-exit probe remains mandatory.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RunnerShutdownContract(unittest.TestCase):
    def test_post_quit_destroys_window_resources_before_com(self):
        compiler = shutil.which('g++') or shutil.which('clang++')
        if not compiler:
            self.skipTest('Portable C++17 facade requires g++ or clang++; native process probe is separate')
        with tempfile.TemporaryDirectory(prefix='silique-runner-order-') as temporary:
            root = Path(temporary)
            (root / 'flutter').mkdir()
            # Compile the complete, byte-identical production entrypoint, rather
            # than reproducing its cleanup logic in the test.
            shutil.copy2(ROOT / 'windows/runner/main.cpp', root / 'main.cpp')
            (root / 'windows.h').write_text(r'''
#pragma once
#include <cassert>
#include <cstdlib>
#define APIENTRY
#define _In_
#define _In_opt_
using HINSTANCE = void*;
constexpr int ATTACH_PARENT_PROCESS = -1;
constexpr int COINIT_APARTMENTTHREADED = 2;
struct MSG {};
inline bool com_active = false;
inline bool native_resources = false;
inline bool message_loop_ended = false;
inline bool AttachConsole(int) { return true; }
inline bool IsDebuggerPresent() { return false; }
inline void CoInitializeEx(void*, int) { com_active = true; }
inline void CoUninitialize() {
  assert(!native_resources && "native resources must be destroyed before COM uninitialization");
  com_active = false;
}
inline int GetMessage(MSG*, void*, int, int) {
  message_loop_ended = true;
  return 0; // window_manager 0.5.2 destroy() posts WM_QUIT.
}
inline void TranslateMessage(MSG*) {}
inline void DispatchMessage(MSG*) {}
''')
            (root / 'flutter/dart_project.h').write_text(r'''
#pragma once
#include <string>
#include <utility>
#include <vector>
namespace flutter {
class DartProject {
 public:
  explicit DartProject(const wchar_t*) {}
  void set_dart_entrypoint_arguments(std::vector<std::string>) {}
};
}
''')
            (root / 'flutter/flutter_view_controller.h').write_text('#pragma once\n')
            (root / 'utils.h').write_text(r'''
#pragma once
inline void CreateAndAttachConsole() {}
inline std::vector<std::string> GetCommandLineArguments() { return {}; }
''')
            (root / 'flutter_window.h').write_text(r'''
#pragma once
class Win32Window {
 public:
  struct Point { Point(int, int) {} };
  struct Size { Size(int, int) {} };
};
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject&) {}
  bool Create(const wchar_t*, Point, Size) {
    assert(com_active);
    native_resources = true;
    return true;
  }
  void SetQuitOnClose(bool) {}
  void Destroy() {
    assert(message_loop_ended && "never destroy before accepted native quit");
    assert(com_active && "teardown must retain COM for plugins");
    native_resources = false;
  }
  ~FlutterWindow() {
    assert(!native_resources && "do not let live controller die by member destruction");
  }
};
''')
            (root / 'probe.cpp').write_text(r'''
#include "main.cpp"
int main() { return wWinMain(nullptr, nullptr, nullptr, 0); }
''')
            probe = root / 'probe'
            subprocess.run([compiler, '-std=c++17', '-I', str(root), str(root / 'probe.cpp'), '-o', str(probe)], check=True)
            completed = subprocess.run([str(probe)], capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)


class FlutterWindowReentrantShutdownContract(unittest.TestCase):
    def test_controller_reset_reentry_does_not_dispatch_or_reload_fonts(self):
        """Model synchronous child teardown, not native Win32/Flutter execution.

        Compile the exact production members; only external declarations and the
        controller's child-destruction callback are faked. This does not establish
        the cause/stack of a native Windows process-exit failure.
        """
        compiler = shutil.which('g++') or shutil.which('clang++')
        if not compiler:
            self.skipTest('Portable C++17 facade requires g++ or clang++; native process probe is separate')
        source = (ROOT / 'windows/runner/flutter_window.cpp').read_text()
        definitions = []
        # These out-of-line definitions end at a column-zero closing brace.
        # Keep every byte of each definition (including its actual function body)
        # rather than copying teardown logic or inspecting guard substrings.
        for signature in (r'void FlutterWindow::OnDestroy\(\)',
                          r'LRESULT\s+FlutterWindow::MessageHandler\('):
            match = re.search(r'^' + signature + r'.*?^}', source,
                              re.MULTILINE | re.DOTALL)
            if match is None:
                self.fail('Cannot extract production member: ' + signature)
            definitions.append(match.group(0))

        with tempfile.TemporaryDirectory(prefix='silique-controller-reentry-') as temporary:
            root = Path(temporary)
            (root / 'production_members.inc').write_text('\n\n'.join(definitions) + '\n')
            (root / 'probe.cpp').write_text(r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <optional>
#include <string>

using HWND = void*;
using UINT = std::uint32_t;
using WPARAM = std::uintptr_t;
using LPARAM = std::intptr_t;
using LRESULT = std::intptr_t;
constexpr UINT WM_CLOSE = 0x0010;
constexpr UINT WM_QUERYENDSESSION = 0x0011;
constexpr UINT WM_FONTCHANGE = 0x001d;
constexpr UINT kOtherMessage = 0x8001;
constexpr LRESULT kBaseResult = 41;

struct Audit {
  int controller_dispatches = 0;
  int font_reloads = 0;
  int channel_destructions = 0;
  int controller_destructions = 0;
  int base_destructions = 0;
  int base_fonts = 0;
  int base_other = 0;
  bool destroying_controller = false;
} audit;

namespace silique {
bool WindowsUpdateBlocksClose() { return false; }
}
class FlutterWindow;
namespace flutter {
struct EncodableValue {};
template <typename T> struct MethodChannel {
  ~MethodChannel() { ++audit.channel_destructions; }
};
struct FlutterEngine {
  int reloads = 0;
  void ReloadSystemFonts() {
    ++reloads;  // Real object access, not a null-tolerant global-counter fake.
    assert(!audit.destroying_controller);
    ++audit.font_reloads;
  }
};
class FlutterViewController {
 public:
  explicit FlutterViewController(FlutterWindow* owner) : owner_(owner) {}
  ~FlutterViewController();
  FlutterEngine* engine() { return &engine_; }
  std::optional<LRESULT> HandleTopLevelWindowProc(HWND, UINT, WPARAM, LPARAM) {
    assert(!audit.destroying_controller);
    ++audit.controller_dispatches;
    return std::nullopt;  // Exercise production WM_FONTCHANGE handling as well.
  }
  bool reenter_on_destroy = true;
 private:
  FlutterWindow* owner_;
  FlutterEngine engine_;
};
}
class Win32Window {
 public:
  void OnDestroy() { ++audit.base_destructions; }
  LRESULT MessageHandler(HWND, UINT message, WPARAM, LPARAM) noexcept {
    if (message == WM_FONTCHANGE) ++audit.base_fonts;
    if (message == kOtherMessage) ++audit.base_other;
    return kBaseResult;
  }
};
class FlutterWindow : public Win32Window {
 public:
  void OnDestroy();
  LRESULT MessageHandler(HWND, UINT, WPARAM, LPARAM) noexcept;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> updates_channel_;
};

#include "production_members.inc"

flutter::FlutterViewController::~FlutterViewController() {
  ++audit.controller_destructions;
  if (!reenter_on_destroy) return;  // Only the separate live-controller smoke.
  audit.destroying_controller = true;
  // unique_ptr reset must already have cleared the parent's stored pointer
  // before deletion synchronously reenters its window message handler.
  assert(!owner_->flutter_controller_);
  assert(!owner_->updates_channel_);
  assert(audit.channel_destructions == 1);
  const int dispatches = audit.controller_dispatches;
  const int reloads = audit.font_reloads;
  const int other = audit.base_other;
  const int fonts = audit.base_fonts;
  assert(owner_->MessageHandler(nullptr, kOtherMessage, 0, 0) == kBaseResult);
  assert(audit.controller_dispatches == dispatches);
  assert(audit.font_reloads == reloads);
  assert(audit.base_other == other + 1);
  std::cerr << "MODELED: reset pointer is null; ordinary destructor reentry passed; "
               "reentering WM_FONTCHANGE\n";
  assert(owner_->MessageHandler(nullptr, WM_FONTCHANGE, 0, 0) == kBaseResult);
  assert(audit.controller_dispatches == dispatches);
  assert(audit.font_reloads == reloads);
  assert(audit.base_fonts == fonts + 1);
}

int main(int argc, char** argv) {
  assert(argc == 2);
  FlutterWindow window;
  window.flutter_controller_ = std::make_unique<flutter::FlutterViewController>(&window);
  window.updates_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>();
  assert(window.MessageHandler(nullptr, WM_FONTCHANGE, 0, 0) == kBaseResult);
  assert(audit.controller_dispatches == 1);
  assert(audit.font_reloads == 1);
  assert(audit.base_fonts == 1);
  assert(audit.controller_destructions == 0);
  assert(audit.channel_destructions == 0);
  std::cerr << "MODELED: live-controller font reload passed\n";
  if (std::string(argv[1]) == "live") {
    window.flutter_controller_->reenter_on_destroy = false;
    return 0;
  }
  assert(std::string(argv[1]) == "reentrant");
  window.OnDestroy();  // Actual production unique_ptr reset calls the destructor.
  assert(!window.flutter_controller_ && !window.updates_channel_);
  assert(audit.controller_destructions == 1);
  assert(audit.channel_destructions == 1);
  assert(audit.base_destructions == 1);
  window.OnDestroy();  // No double destruction or new controller callbacks.
  assert(audit.controller_destructions == 1);
  assert(audit.channel_destructions == 1);
  assert(audit.base_destructions == 2);
  assert(window.MessageHandler(nullptr, kOtherMessage, 0, 0) == kBaseResult);
  assert(window.MessageHandler(nullptr, WM_FONTCHANGE, 0, 0) == kBaseResult);
  assert(audit.controller_dispatches == 1);
  assert(audit.font_reloads == 1);
  assert(audit.base_other == 2);
  assert(audit.base_fonts == 3);
  std::cerr << "MODELED: destructor reentry, late messages and repeated OnDestroy passed\n";
}
''')
            probe = root / 'probe'
            # UBSan makes the unguarded null member call a deterministic runtime
            # failure with diagnostics, rather than depending on SIGSEGV or UB.
            compiled = subprocess.run(
                [compiler, '-std=c++17', '-O0', '-g', '-fsanitize=undefined',
                 '-fno-sanitize-recover=all', str(root / 'probe.cpp'), '-o', str(probe)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0,
                             'Facade must compile before behavioral checks:\n' + compiled.stderr)
            for scenario in ('live', 'reentrant'):
                with self.subTest(scenario=scenario):
                    completed = subprocess.run([str(probe), scenario],
                                               capture_output=True, text=True, timeout=20)
                    self.assertEqual(
                        completed.returncode, 0,
                        'Compiled production members failed the modeled ' + scenario +
                        ' contract (not native Windows evidence):\n' +
                        completed.stdout + completed.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
