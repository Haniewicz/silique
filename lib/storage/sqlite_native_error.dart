import 'dart:ffi';
import 'dart:io';

int Function()? _lastWindowsError;

/// Resolve before opening SQLite so DLL loading cannot overwrite the thread's
/// error while capturing it. Bundled package:sqlite3 libraries do not export
/// sqlite3_system_errno/file_control: do NOT call a different system SQLite
/// with a handle from the bundled one, or require absent symbols in AOT builds.
void prepareNativeErrorCapture() {
  if (!Platform.isWindows || _lastWindowsError != null) return;
  _lastWindowsError = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}

Map<String, Object?> sqliteNativeError() {
  final hint = _lastWindowsError?.call();
  return {
    // Only a hint: SQLite may have made other Win32 calls since WriteFile
    // failed. Never assert a diagnosis or report errno=0 success from it.
    'win32_last_error_hint': ?hint,
    'native_error_source': hint == null
        ? 'unavailable_in_bundled_sqlite'
        : 'GetLastError_best_effort',
  };
}
