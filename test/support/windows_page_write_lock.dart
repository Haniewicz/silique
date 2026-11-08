import 'dart:ffi';

/// Actual Windows shared byte lock: reads are allowed, writes to page 0 fail in
/// WriteFile with ERROR_LOCK_VIOLATION. This is NOT a thrown SQLite exception or
/// a mocked PRAGMA. Use only on disposable test databases.
final class WindowsPageWriteLock {
  WindowsPageWriteLock(String path, {bool mapFile = false, int length = 4096}) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final alloc = kernel
        .lookupFunction<
          Pointer<Void> Function(Uint32, UintPtr),
          Pointer<Void> Function(int, int)
        >('LocalAlloc');
    _free = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    _close = kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'CloseHandle',
    );
    final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final create = kernel
        .lookupFunction<
          IntPtr Function(
            Pointer<Uint16>,
            Uint32,
            Uint32,
            Pointer<Void>,
            Uint32,
            Uint32,
            IntPtr,
          ),
          int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    final lock = kernel
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Uint32, Uint32, Uint32, Pointer<Void>),
          int Function(int, int, int, int, int, Pointer<Void>)
        >('LockFileEx');
    final createMapping = kernel
        .lookupFunction<
          IntPtr Function(
            IntPtr,
            Pointer<Void>,
            Uint32,
            Uint32,
            Uint32,
            Pointer<Uint16>,
          ),
          int Function(int, Pointer<Void>, int, int, int, Pointer<Uint16>)
        >('CreateFileMappingW');
    final mapView = kernel
        .lookupFunction<
          Pointer<Void> Function(IntPtr, Uint32, Uint32, Uint32, UintPtr),
          Pointer<Void> Function(int, int, int, int, int)
        >('MapViewOfFile');
    _unmap = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('UnmapViewOfFile');
    final name = alloc(0x40, (path.length + 1) * 2).cast<Uint16>();
    _overlap = alloc(0x40, 32);
    try {
      name.asTypedList(path.length + 1).setAll(0, path.codeUnits);
      _handle = create(name, 0x80000000, 7, nullptr, 3, 0x80, 0);
      if (_handle == -1) throw StateError('CreateFileW: ${lastError()}');
      if (mapFile) {
        // Any mapped view prevents truncating SHM. SQLite 3.54 then attempts
        // winZeroSharedMemory, an eight-byte WriteFile at offset zero.
        _mapping = createMapping(_handle, nullptr, 2, 0, 0, nullptr);
        if (_mapping == 0) {
          throw StateError('CreateFileMappingW: ${lastError()}');
        }
        _view = mapView(_mapping, 4, 0, 0, 0);
        if (_view == nullptr) throw StateError('MapViewOfFile: ${lastError()}');
      }
      // Shared lock: no LOCKFILE_EXCLUSIVE_LOCK bit. Reads remain permitted.
      if (lock(_handle, 1, 0, length, 0, _overlap) == 0) {
        throw StateError('LockFileEx: ${lastError()}');
      }
    } catch (_) {
      close();
      rethrow;
    } finally {
      _free(name.cast());
    }
  }
  int _handle = -1;
  int _mapping = 0;
  Pointer<Void> _view = nullptr;
  Pointer<Void> _overlap = nullptr;
  late Pointer<Void> Function(Pointer<Void>) _free;
  late int Function(int) _close;
  late int Function(Pointer<Void>) _unmap;
  void close() {
    if (_view != nullptr) {
      _unmap(_view);
      _view = nullptr;
    }
    if (_mapping != 0) {
      _close(_mapping);
      _mapping = 0;
    }
    if (_handle != -1) {
      _close(_handle);
      _handle = -1;
    }
    if (_overlap != nullptr) {
      _free(_overlap);
      _overlap = nullptr;
    }
  }
}
