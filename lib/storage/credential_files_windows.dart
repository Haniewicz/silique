part of 'credential_files.dart';

/// Windows has no unprivileged POSIX directory-fsync equivalent. Publication
/// uses a flushed, write-through source plus same-volume MoveFileExW with
/// REPLACE_EXISTING | WRITE_THROUGH, never delete-before-rename. Removal publishes
/// a one-byte non-secret tombstone through that same primitive, not DeleteFile.
/// This provides the Windows documented move guarantee, not a power-cut test or
/// a guarantee for storage hardware that lies about flush completion.
class _WindowsCredentialSession extends _CredentialSession {
  _WindowsCredentialSession(Directory directory) {
    _path = directory.absolute.path.replaceAll('/', r'\');
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(_path)) {
      throw FileSystemException('Credentials require a local drive path');
    }
    final components = _path
        .substring(3)
        .split(r'\')
        .where((p) => p.isNotEmpty);
    var path = _path.substring(0, 3);
    try {
      _parents.add(_w.open(path, directory: true));
      _w.inspect(_parents.last, directory: true);
      for (final component in components) {
        if (component == '.' ||
            component == '..' ||
            component.endsWith('.') ||
            component.endsWith(' ') ||
            component.contains(':')) {
          throw FileSystemException('Unsafe credential directory component');
        }
        path = path.endsWith(r'\') ? '$path$component' : '$path\\$component';
        var handle = _w.tryOpen(path, directory: true);
        if (_w.invalid(handle)) {
          if (_w.openError != 2 && _w.openError != 3) {
            _w.fail('open credential directory', _w.openError);
          }
          _w.createDirectory(path);
          handle = _w.open(path, directory: true);
        }
        _parents.add(handle);
        _w.inspect(handle, directory: true);
      }
      // Omitting FILE_SHARE_DELETE pins every ancestor against renaming and
      // removal, so absolute child operations cannot be redirected mid-action.
      _w.private(_parents.last);
    } catch (_) {
      close();
      rethrow;
    }
  }

  static final _w = _Windows();
  late final String _path;
  final List<Pointer<Void>> _parents = [];
  Pointer<Void>? _lock;

  String _child(String name) => '$_path\\$name';

  @override
  Future<void> acquire() async {
    final handle = _w.open(
      _child('lock'),
      writable: true,
      creation: 4,
      share: 3,
    );
    _lock = handle;
    _w.inspect(handle, directory: false);
    _w.private(handle);
    final overlapped = calloc<win.OVERLAPPED>();
    try {
      while (_w.lockFile(handle, 3, 0, 1, 0, overlapped) == 0) {
        if (_w.lockError != 33) {
          _w.fail('acquire credential lock', _w.lockError);
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      calloc.free(overlapped);
    }
  }

  Pointer<Void>? _existing(String name) {
    final handle = _w.tryOpen(_child(name), share: 7);
    if (_w.invalid(handle)) {
      if (_w.openError == 2) return null;
      _w.fail('open credential file', _w.openError);
    }
    try {
      _w.inspect(handle, directory: false);
      _w.private(handle);
      return handle;
    } catch (_) {
      _w.close(handle);
      rethrow;
    }
  }

  void _discardPending(String name) {
    final temp = '.pending-$name';
    final handle = _existing(temp);
    if (handle == null) return;
    _w.close(handle);
    // Ancestors remain pinned and the native lock excludes other writers.
    // Retire plaintext durably before deleting non-secret temp metadata.
    _w.eraseFailedTemporary(_child(temp));
  }

  @override
  String? read(String name) {
    _discardPending(name);
    final handle = _existing(name);
    if (handle == null) return null;
    final buffer = calloc<Uint8>(16384);
    final count = calloc<Uint32>();
    final bytes = BytesBuilder(copy: true);
    try {
      while (true) {
        if (_w.readFile(handle, buffer.cast(), 16384, count, nullptr) == 0) {
          _w.fail('read credential file');
        }
        if (count.value == 0) break;
        bytes.add(buffer.asTypedList(count.value));
      }
      final value = _decodeCredentialBytes(bytes.takeBytes());
      if (value == 'D') return null;
      if (!value.startsWith('V')) {
        throw FileSystemException('Invalid credential file envelope');
      }
      return value.substring(1);
    } finally {
      buffer.asTypedList(16384).fillRange(0, 16384, 0);
      calloc.free(buffer);
      calloc.free(count);
      _w.close(handle);
    }
  }

  @override
  void write(String name, String value) => _replace(name, 'V$value');

  @override
  void remove(String name) {
    if (read(name) == null) return;
    _replace(name, 'D');
  }

  void _replace(String name, String value) {
    _discardPending(name);
    final old = _existing(name);
    if (old != null) _w.close(old);
    final temp = _child('.pending-$name');
    var handle = _w.open(
      temp,
      writable: true,
      creation: 1,
      share: 7,
      writeThrough: true,
    );
    final bytes = utf8.encode(value);
    final buffer = calloc<Uint8>(bytes.length);
    final count = calloc<Uint32>();
    var published = false;
    try {
      _w.inspect(handle, directory: false);
      _w.private(handle);
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final length = min(bytes.length - offset, 0x40000000);
        if (_w.writeFile(
                  handle,
                  (buffer + offset).cast(),
                  length,
                  count,
                  nullptr,
                ) ==
                0 ||
            count.value == 0) {
          _w.fail('write credential file');
        }
        offset += count.value;
      }
      _w.flush(handle);
      _w.close(handle);
      handle = nullptr;
      _w.move(temp, _child(name));
      published = true;
    } finally {
      buffer.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(buffer);
      calloc.free(count);
      if (handle != nullptr) _w.close(handle);
      // Never unlink a plaintext failed source without flushing it. Keep a
      // private source on failure, and report the failure; migration must not
      // activate/delete the old authoritative credential source in that case.
      if (!published) _w.eraseFailedTemporary(temp);
    }
  }

  @override
  void close() {
    try {
      final lock = _lock;
      if (lock != null) _w.close(lock); // closing releases LockFileEx
    } finally {
      for (final handle in _parents.reversed) {
        _w.close(handle);
      }
      _parents.clear();
    }
  }
}

class _Windows {
  _Windows() {
    // Resolve before any failing Win32 operation: lazy symbol lookup can
    // overwrite the thread-local error. The getter must not enter the VM.
    _getError();
  }

  final _kernel = DynamicLibrary.open('kernel32.dll');
  final _security = DynamicLibrary.open('advapi32.dll');
  late final _bridge = DynamicLibrary.open(_bridgePath());

  String _bridgePath() {
    const name = 'silique_credential_io.dll';
    final bundled = File(
      '${File(Platform.resolvedExecutable).parent.path}/$name',
    );
    if (bundled.existsSync()) return bundled.absolute.path;
    // Host tests run in flutter_tester, outside the application bundle.
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return File('build/credential_native/Release/$name').absolute.path;
    }
    throw FileSystemException('Native credential IO library is missing');
  }

  late final _getError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
        isLeaf: true,
      );
  int get error => _getError();
  int openError =
      0; // captured before LocalFree/allocator cleanup can change it
  bool invalid(Pointer<Void> handle) =>
      handle.address == -1 ||
      handle.address == 0xffffffffffffffff ||
      handle.address == 0xffffffff;
  Never fail(String operation, [int? code]) => throw FileSystemException(
    operation,
    '',
    OSError('Native credential operation failed', code ?? error),
  );

  late final _createFile = _bridge
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<win.SECURITY_ATTRIBUTES>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Pointer<Uint32>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<win.SECURITY_ATTRIBUTES>,
          int,
          int,
          Pointer<Void>,
          Pointer<Uint32>,
        )
      >('SiliqueCredentialOpen');
  Pointer<Void> tryOpen(
    String path, {
    bool directory = false,
    bool writable = false,
    int creation = 3,
    int share = 3,
    bool writeThrough = false,
  }) {
    final name = path.toNativeUtf16();
    final captured = calloc<Uint32>();
    try {
      return _attributes(directory, (attributes) {
        final handle = _createFile(
          name,
          0x20000 |
              (directory ? 0x80 : 0x80000000) |
              (writable ? 0x40000000 : 0),
          share,
          attributes,
          creation,
          0x200000 |
              (directory ? 0x2000000 : 0) |
              (writeThrough ? 0x80000000 : 0),
          nullptr,
          captured,
        );
        openError = captured.value;
        return handle;
      });
    } finally {
      malloc.free(name);
      calloc.free(captured);
    }
  }

  Pointer<Void> open(
    String path, {
    bool directory = false,
    bool writable = false,
    int creation = 3,
    int share = 3,
    bool writeThrough = false,
  }) {
    final handle = tryOpen(
      path,
      directory: directory,
      writable: writable,
      creation: creation,
      share: share,
      writeThrough: writeThrough,
    );
    if (invalid(handle)) fail('open private credential handle', openError);
    return handle;
  }

  late final _createDirectory = _bridge
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<win.SECURITY_ATTRIBUTES>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<win.SECURITY_ATTRIBUTES>,
          Pointer<Uint32>,
        )
      >('SiliqueCredentialMkdir');
  void createDirectory(String path) {
    final name = path.toNativeUtf16();
    final captured = calloc<Uint32>();
    try {
      var failure = 0;
      final result = _attributes(true, (attributes) {
        final result = _createDirectory(name, attributes, captured);
        failure = captured.value;
        return result;
      });
      if (result == 0 && failure != 183) {
        fail('create private credential directory', failure);
      }
    } finally {
      malloc.free(name);
      calloc.free(captured);
    }
  }

  late final _close = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  void close(Pointer<Void> handle) {
    if (_close(handle) == 0) fail('close credential handle');
  }

  int lockError = 0;
  int lockFile(
    Pointer<Void> handle,
    int flags,
    int reserved,
    int low,
    int high,
    Pointer<win.OVERLAPPED> overlapped,
  ) {
    final captured = calloc<Uint32>();
    try {
      final result = _lockFile(
        handle,
        flags,
        reserved,
        low,
        high,
        overlapped,
        captured,
      );
      lockError = captured.value;
      return result;
    } finally {
      calloc.free(captured);
    }
  }

  late final _lockFile = _bridge
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Uint32,
          Uint32,
          Uint32,
          Pointer<win.OVERLAPPED>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          int,
          int,
          Pointer<win.OVERLAPPED>,
          Pointer<Uint32>,
        )
      >('SiliqueCredentialLock');
  late final readFile = _kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('ReadFile');
  late final writeFile = _kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('WriteFile');
  late final _flush = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FlushFileBuffers');
  void flush(Pointer<Void> handle) {
    if (_flush(handle) == 0) fail('flush credential file');
  }

  late final _move = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('MoveFileExW');
  void move(String from, String to) {
    final source = from.toNativeUtf16();
    final target = to.toNativeUtf16();
    try {
      if (_move(source, target, 1 | 8) == 0) fail('publish credential file');
    } finally {
      malloc.free(source);
      malloc.free(target);
    }
  }

  late final _info = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<win.BY_HANDLE_FILE_INFORMATION>),
        int Function(Pointer<Void>, Pointer<win.BY_HANDLE_FILE_INFORMATION>)
      >('GetFileInformationByHandle');
  void inspect(Pointer<Void> handle, {required bool directory}) {
    final info = calloc<win.BY_HANDLE_FILE_INFORMATION>();
    try {
      if (_info(handle, info) == 0) fail('inspect credential handle');
      if ((info.ref.dwFileAttributes & 0x400) != 0 ||
          ((info.ref.dwFileAttributes & 0x10) != 0) != directory ||
          (!directory && info.ref.nNumberOfLinks != 1)) {
        throw FileSystemException(
          'Credential reparse point, type or hard links are unsafe',
        );
      }
    } finally {
      calloc.free(info);
    }
  }

  // Security-sensitive functions missing from win32 v6's selected surface are
  // bound directly; ABI-sensitive public structs come from win32, not guesses.
  late final _convert = _security
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
  late final _free = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  T _attributes<T>(
    bool directory,
    T Function(Pointer<win.SECURITY_ATTRIBUTES>) operation,
  ) {
    final inheritance = directory ? 'OICI' : '';
    final sddl =
        'O:$_userSid'
                'D:P(A;$inheritance;FA;;;$_userSid)(A;$inheritance;FA;;;SY)'
            .toNativeUtf16();
    final descriptor = calloc<Pointer<Void>>();
    final attributes = calloc<win.SECURITY_ATTRIBUTES>();
    try {
      if (_convert(sddl, 1, descriptor, nullptr) == 0) {
        fail('create private credential ACL');
      }
      attributes.ref
        ..nLength = sizeOf<win.SECURITY_ATTRIBUTES>()
        ..lpSecurityDescriptor = descriptor.value
        ..bInheritHandle = false;
      return operation(attributes);
    } finally {
      if (descriptor.value != nullptr) _free(descriptor.value);
      calloc.free(descriptor);
      calloc.free(attributes);
      malloc.free(sddl);
    }
  }

  late final _getProcess = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  late final _openToken = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('OpenProcessToken');
  late final _tokenInfo = _security
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetTokenInformation');
  late final _sidToString = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
      >('ConvertSidToStringSidW');
  late final String _userSid = _currentUser();
  String _currentUser() {
    final token = calloc<Pointer<Void>>();
    final length = calloc<Uint32>();
    Pointer<Uint8> info = nullptr;
    final sid = calloc<Pointer<Utf16>>();
    try {
      if (_openToken(_getProcess(), 8, token) == 0) {
        fail('query credential owner');
      }
      _tokenInfo(token.value, 1, nullptr, 0, length);
      if (length.value == 0) fail('size credential owner token');
      info = calloc<Uint8>(length.value);
      if (_tokenInfo(token.value, 1, info.cast(), length.value, length) == 0) {
        fail('query credential owner token');
      }
      // TOKEN_USER begins with SID_AND_ATTRIBUTES; its first member is PSID.
      if (_sidToString(info.cast<Pointer<Void>>().value, sid) == 0) {
        fail('query credential owner SID');
      }
      return sid.value.toDartString();
    } finally {
      if (sid.value != nullptr) _free(sid.value.cast());
      if (info != nullptr) calloc.free(info);
      if (token.value != nullptr) close(token.value);
      calloc.free(token);
      calloc.free(length);
      calloc.free(sid);
    }
  }

  late final _getSecurity = _security
      .lookupFunction<
        Uint32 Function(
          Pointer<Void>,
          Int32,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<win.ACL>>,
          Pointer<Pointer<win.ACL>>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<win.ACL>>,
          Pointer<Pointer<win.ACL>>,
          Pointer<Pointer<Void>>,
        )
      >('GetSecurityInfo');
  late final _control = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>)
      >('GetSecurityDescriptorControl');
  late final _getAce = _security
      .lookupFunction<
        Int32 Function(Pointer<win.ACL>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<win.ACL>, int, Pointer<Pointer<Void>>)
      >('GetAce');
  String _sidString(Pointer<Void> sid) {
    final text = calloc<Pointer<Utf16>>();
    try {
      if (_sidToString(sid, text) == 0) fail('inspect credential ACL SID');
      return text.value.toDartString();
    } finally {
      if (text.value != nullptr) _free(text.value.cast());
      calloc.free(text);
    }
  }

  void private(Pointer<Void> handle) {
    final owner = calloc<Pointer<Void>>();
    final acl = calloc<Pointer<win.ACL>>();
    final descriptor = calloc<Pointer<Void>>();
    final control = calloc<Uint16>();
    final revision = calloc<Uint32>();
    final ace = calloc<Pointer<Void>>();
    try {
      final result = _getSecurity(
        handle,
        1,
        1 | 4,
        owner,
        nullptr,
        acl,
        nullptr,
        descriptor,
      );
      if (result != 0) {
        throw FileSystemException(
          'Inspect credential security',
          '',
          OSError('Security descriptor unavailable', result),
        );
      }
      if (_control(descriptor.value, control, revision) == 0) {
        fail('inspect credential ACL protection');
      }
      if (_sidString(owner.value) != _userSid ||
          acl.value == nullptr ||
          (control.value & 0x1000) == 0) {
        throw FileSystemException(
          'Credential owner or inherited ACL is unsafe',
        );
      }
      var ownerAllowed = false;
      for (var index = 0; index < acl.value.ref.AceCount; index++) {
        if (_getAce(acl.value, index, ace) == 0) fail('inspect credential ACE');
        // ACCESS_ALLOWED_ACE: ACE_HEADER (4 bytes), ACCESS_MASK (4), SID.
        final bytes = ace.value.cast<Uint8>();
        final header = ByteData.sublistView(bytes.asTypedList(8));
        if (header.getUint8(0) != 0 ||
            (header.getUint8(1) & 8) != 0 ||
            header.getUint16(2, Endian.host) < 12 ||
            header.getUint32(4, Endian.host) != 0x1f01ff) {
          throw FileSystemException('Credential ACL contains an unsafe ACE');
        }
        // Inspect SID only after confirming the simple allowed-ACE layout.
        final sid = _sidString((bytes + 8).cast());
        if (sid != _userSid && sid != 'S-1-5-18') {
          throw FileSystemException('Credential ACL grants unsafe access');
        }
        if (sid == _userSid) ownerAllowed = true;
      }
      if (!ownerAllowed) {
        throw FileSystemException('Credential ACL denies its owner');
      }
    } finally {
      if (descriptor.value != nullptr) _free(descriptor.value);
      calloc.free(owner);
      calloc.free(acl);
      calloc.free(descriptor);
      calloc.free(control);
      calloc.free(revision);
      calloc.free(ace);
    }
  }

  void eraseFailedTemporary(String path) {
    // A failed atomic replace must not leave an extra live plaintext copy.
    // Overwrite only this already-private, lock-protected temp with a
    // tombstone and flush it before deleting its non-secret filename.
    // If that flush fails, propagate the error and leave the source;
    // never silently delete an unflushed source as a cleanup fallback.
    final handle = open(path, writable: true, creation: 3, share: 7);
    final byte = calloc<Uint8>()..value = 68; // D
    final count = calloc<Uint32>();
    try {
      inspect(handle, directory: false);
      private(handle);
      if (writeFile(handle, byte.cast(), 1, count, nullptr) == 0 ||
          count.value != 1) {
        fail('retire failed credential temporary');
      }
      if (_setEnd(handle) == 0) fail('truncate failed credential temporary');
      flush(handle);
    } finally {
      calloc.free(byte);
      calloc.free(count);
      close(handle);
    }
    final name = path.toNativeUtf16();
    try {
      if (_deleteFile(name) == 0) fail('remove retired credential temporary');
    } finally {
      malloc.free(name);
    }
  }

  late final _deleteFile = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('DeleteFileW');

  late final _setEnd = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('SetEndOfFile');
}
