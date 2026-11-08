part of 'credential_files.dart';

// openat/mkdirat walk pins every component and refuses symlinks. No plaintext
// passes through Dart File APIs or through a chmod-after-creation interval.
class _PosixCredentialSession extends _CredentialSession {
  _PosixCredentialSession(Directory directory) {
    if (_p._mac) {
      // App Sandbox may grant the container without read access to its
      // ancestors (for example Library). Opening each ancestor O_RDONLY
      // requests directory listing rights and fails with EPERM. Pin the full
      // path instead; O_NOFOLLOW_ANY preserves rejection of *every* symlink,
      // not merely the last component. Never broaden sandbox entitlements.
      final path = directory.absolute.path;
      if (path.split('/').any((part) => part == '.' || part == '..')) {
        throw FileSystemException('Unsafe credential directory');
      }
      final fd = _p.openMacDirectory(path);
      try {
        _p.validate(fd, directory: true);
        _directory = fd;
      } catch (_) {
        _p.close(fd);
        rethrow;
      }
      return;
    }
    // Linux/Android ancestors use O_PATH: /data is traversable but not readable.
    var fd = _p.openAt(_p.atCwd, '/', _p.pathFlags);
    try {
      final components = directory.absolute.path
          .split('/')
          .where((p) => p.isNotEmpty)
          .toList();
      for (var index = 0; index < components.length; index++) {
        final component = components[index];
        if (component == '.' || component == '..') {
          throw FileSystemException('Unsafe credential directory');
        }
        // Only the credential directory itself must support fsync and
        // open-at-file operations, so only it gets a readable handle.
        final flags = index == components.length - 1
            ? _p.directoryFlags
            : _p.pathFlags;
        var next = _p.tryOpenAt(fd, component, flags);
        if (next < 0 && _p.errno == 2) {
          _p.createDirectoryAt(fd, component);
          next = _p.openAt(fd, component, flags);
        }
        if (next < 0) _p.fail('open credential directory');
        _p.close(fd);
        fd = next;
      }
      _p.validate(fd, directory: true);
      _directory = fd;
    } catch (_) {
      _p.close(fd);
      rethrow;
    }
  }

  static final _p = _Posix();
  late final int _directory;
  int? _lock;

  @override
  Future<void> acquire() async {
    final fd = _p.openAt(_directory, 'lock', _p.fileFlags | 2 | _p.create);
    _lock = fd;
    _p.validate(fd, directory: false);
    _p.sync(fd);
    _p.sync(_directory);
    // flock is tied to an open file description, not a PID. Separate instances
    // and isolates therefore contend too. Never block the Dart event loop.
    while (_p.flock(fd, 2 | 4) != 0) {
      if (_p.errno != 11 && _p.errno != 35 && _p.errno != 4) {
        _p.fail('acquire credential lock');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  int? _existing(String name) {
    final fd = _p.tryOpenAt(_directory, name, _p.fileFlags);
    if (fd < 0) {
      if (_p.errno == 2) return null;
      _p.fail('open credential file');
    }
    try {
      _p.validate(fd, directory: false);
      return fd;
    } catch (_) {
      _p.close(fd);
      rethrow;
    }
  }

  // Called only while holding the directory's native lock. Pin and validate
  // the exact known temp; never enumerate/delete through a pathname fallback.
  void _discardPending(String name) {
    final temp = '.pending-$name';
    final fd = _existing(temp);
    if (fd == null) return;
    try {
      _p.unlinkAt(_directory, temp);
      _p.sync(_directory);
    } finally {
      _p.close(fd);
    }
  }

  @override
  String? read(String name) {
    _discardPending(name);
    final fd = _existing(name);
    if (fd == null) return null;
    final buffer = calloc<Uint8>(16384);
    final bytes = BytesBuilder(copy: true);
    try {
      while (true) {
        final count = _p.read(fd, buffer.cast(), 16384);
        if (count < 0) {
          if (_p.errno == 4) continue;
          _p.fail('read credential file');
        }
        if (count == 0) break;
        bytes.add(buffer.asTypedList(count));
      }
      return _decodeCredentialBytes(bytes.takeBytes());
    } finally {
      calloc.free(buffer);
      _p.close(fd);
    }
  }

  @override
  void write(String name, String value) {
    _discardPending(name);
    final previous = _existing(name);
    if (previous != null) _p.close(previous);
    // One known staging basename per target makes crash leftovers recoverable.
    final temp = '.pending-$name';
    final fd = _p.openAt(
      _directory,
      temp,
      _p.fileFlags | 1 | _p.create | _p.exclusive,
    );
    var published = false;
    final bytes = utf8.encode(value);
    final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      _p.validate(fd, directory: false);
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final written = _p.write(
          fd,
          (buffer + offset).cast(),
          bytes.length - offset,
        );
        if (written < 0 && _p.errno == 4) continue;
        if (written <= 0) _p.fail('write credential file');
        offset += written;
      }
      _p.sync(fd, data: true);
      _p.renameAt(_directory, temp, name);
      published = true;
      _p.sync(_directory);
    } finally {
      // Best effort memory hygiene; not a managed-runtime forensic wipe promise.
      buffer
          .asTypedList(bytes.isEmpty ? 1 : bytes.length)
          .fillRange(0, bytes.isEmpty ? 1 : bytes.length, 0);
      calloc.free(buffer);
      _p.close(fd);
      if (!published) {
        _p.unlinkAt(_directory, temp);
        _p.sync(_directory);
      }
    }
  }

  @override
  void remove(String name) {
    _discardPending(name);
    final fd = _existing(name);
    if (fd == null) return;
    try {
      _p.unlinkAt(_directory, name);
      _p.sync(_directory);
    } finally {
      _p.close(fd);
    }
  }

  @override
  void close() {
    try {
      final lock = _lock;
      if (lock != null) _p.close(lock); // close releases flock even on errors
    } finally {
      _p.close(_directory);
    }
  }
}

class _Posix {
  _Posix() {
    // Reject unknown ABIs instead of interpreting an unverified struct stat.
    if (!{
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.androidX64,
      Abi.androidArm64,
      Abi.androidArm,
      Abi.androidIA32,
      Abi.macosX64,
      Abi.macosArm64,
    }.contains(Abi.current())) {
      throw UnsupportedError('Unsupported credential filesystem ABI');
    }
  }

  final _lib = DynamicLibrary.process();
  bool get _mac => Platform.isMacOS;
  int get atCwd => _mac ? -2 : -100;
  int get create => _mac ? 0x200 : 0x40;
  int get exclusive => _mac ? 0x800 : 0x80;
  bool get _arm => {
    Abi.linuxArm64,
    Abi.androidArm64,
    Abi.androidArm,
  }.contains(Abi.current());
  int get fileFlags =>
      (_mac
          ? 0x100
          : _arm
          ? 0x8000
          : 0x20000) | // O_NOFOLLOW
      (_mac ? 0x1000000 : 0x80000) | // O_CLOEXEC
      (_mac ? 0x4 : 0x800); // O_NONBLOCK prevents FIFO hangs
  int get _noFollow => _mac
      ? 0x100
      : _arm
      ? 0x8000
      : 0x20000;
  int get _directoryOnly => _mac
      ? 0x100000
      : _arm
      ? 0x4000
      : 0x10000;
  int get directoryFlags => fileFlags | _directoryOnly;
  // O_PATH (0x200000) on Linux and Android: no read permission required.
  int get pathFlags =>
      _mac ? directoryFlags : 0x200000 | 0x80000 | _noFollow | _directoryOnly;

  int openMacDirectory(String path) {
    const noFollowAny =
        0x20000000; // Darwin O_NOFOLLOW_ANY, all path components.
    // Darwin returns EINVAL if O_NOFOLLOW and O_NOFOLLOW_ANY are combined.
    final flags = (directoryFlags & ~_noFollow) | noFollowAny;
    final fd = tryOpenAt(atCwd, path, flags);
    if (fd >= 0) return fd;
    if (errno != 2 || path == '/') {
      fail('open credential directory');
    }
    // Only missing paths need a readable parent. Existing container ancestors
    // are resolved by the kernel, not separately opened by the application.
    final separator = path.lastIndexOf('/');
    final parent = openMacDirectory(
      separator == 0 ? '/' : path.substring(0, separator),
    );
    try {
      final name = path.substring(separator + 1);
      createDirectoryAt(parent, name);
      sync(parent);
      return openAt(parent, name, flags);
    } finally {
      close(parent);
    }
  }

  late final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        _mac
            ? '__error'
            : Platform.isAndroid
            ? '__errno'
            : '__errno_location',
      );
  int get errno => _errno().value;
  Never fail(String operation) => throw FileSystemException(
    operation,
    '',
    OSError('Native credential operation failed', errno),
  );

  bool get _mode16 =>
      _mac || {Abi.androidArm, Abi.androidIA32}.contains(Abi.current());

  // C integer promotion turns a 16-bit mode_t into int in openat's varargs.
  // VarArgs also selects Darwin ARM64's distinct variadic calling convention.
  late final _openat = _mode16
      ? _lib.lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
          int Function(int, Pointer<Utf8>, int, int)
        >('openat')
      : _lib.lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
          int Function(int, Pointer<Utf8>, int, int)
        >('openat');
  int tryOpenAt(int parent, String name, int flags) {
    final path = name.toNativeUtf8();
    try {
      return _openat(parent, path, flags, 0x180);
    } finally {
      malloc.free(path);
    }
  }

  int openAt(int parent, String name, int flags) {
    final fd = tryOpenAt(parent, name, flags);
    if (fd < 0) fail('open private credential file');
    return fd;
  }

  // mode_t is 16-bit on Darwin and bionic's 32-bit ABIs, but 32-bit on the
  // other supported ABIs. Unlike openat's promoted vararg, mkdirat takes
  // mode_t as a fixed parameter and must use its exact native width.
  late final _mkdirat = _mode16
      ? _lib.lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Uint16),
          int Function(int, Pointer<Utf8>, int)
        >('mkdirat')
      : _lib.lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Uint32),
          int Function(int, Pointer<Utf8>, int)
        >('mkdirat');
  void createDirectoryAt(int parent, String name) {
    mkdirAt(parent, name);
    // fsync the new entry through a readable handle: O_PATH handles reject it.
    final created = tryOpenAt(parent, name, directoryFlags);
    if (created >= 0) {
      try {
        sync(created);
      } finally {
        close(created);
      }
    }
  }

  void mkdirAt(int parent, String name) {
    final path = name.toNativeUtf8();
    try {
      if (_mkdirat(parent, path, 0x1c0) != 0 && errno != 17) {
        fail('create private credential directory');
      }
    } finally {
      malloc.free(path);
    }
  }

  late final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  void close(int fd) {
    if (_close(fd) != 0) fail('close credential handle');
  }

  late final read = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, UintPtr),
        int Function(int, Pointer<Void>, int)
      >('read');
  late final write = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, UintPtr),
        int Function(int, Pointer<Void>, int)
      >('write');
  late final _sync = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  late final _fcntl = _lib
      .lookupFunction<
        Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
        int Function(int, int, int)
      >('fcntl');
  void sync(int fd, {bool data = false}) {
    if (_sync(fd) != 0) fail('flush credential file or directory');
    // fsync alone on Darwin may stop at the drive cache. F_FULLFSYNC asks the
    // device to commit; failure is not silently downgraded to ordinary fsync.
    if (_mac && data && _fcntl(fd, 51, 0) != 0) {
      fail('full flush credential file');
    }
  }

  late final _renameat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>)
      >('renameat');
  void renameAt(int parent, String from, String to) {
    final source = from.toNativeUtf8();
    final target = to.toNativeUtf8();
    try {
      if (_renameat(parent, source, parent, target) != 0) {
        fail('publish credential file');
      }
    } finally {
      malloc.free(source);
      malloc.free(target);
    }
  }

  late final _unlinkat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32),
        int Function(int, Pointer<Utf8>, int)
      >('unlinkat');
  void unlinkAt(int parent, String name) {
    final path = name.toNativeUtf8();
    try {
      if (_unlinkat(parent, path, 0) != 0) fail('remove credential file');
    } finally {
      malloc.free(path);
    }
  }

  late final flock = _lib
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  late final _uid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  );
  late final _fstat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >(
        _mac && Abi.current() == Abi.macosX64
            ? r'fstat$INODE64'
            : Platform.isAndroid
            ? 'fstat64'
            : 'fstat',
      );
  late final _aclGetFd = _lib
      .lookupFunction<
        Pointer<Void> Function(Int32, Int32),
        Pointer<Void> Function(int, int)
      >('acl_get_fd_np');
  late final _aclGetEntry = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('acl_get_entry');
  late final _aclFree = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free');

  void _validateMacAcl(int fd) {
    // Darwin ACL grants are independent of mode bits: even 0600/0700 can
    // expose credentials. Reject every extended entry rather than attempting
    // to interpret principals, deny ordering or inherited grants. Inspect the
    // pinned handle, never a path that could have been redirected.
    final acl = _aclGetFd(fd, 0x100); // ACL_TYPE_EXTENDED
    if (acl == nullptr) {
      // Apple Libc acl_file.c / gen/filesec.c: on this already-stat'ed fd,
      // NULL/ENOENT means FILESEC_ACL is absent, not a missing pathname.
      // Other query failures (including unsupported ACLs) remain fatal.
      if (errno == 2) return;
      fail('inspect credential ACL');
    }
    final entry = calloc<Pointer<Void>>();
    try {
      // Apple Libc posix1e/acl_entry.c: 0 means an entry was found; -1/EINVAL
      // means the valid ACL is empty. This is NOT Linux libacl's 1/0 contract.
      final result = _aclGetEntry(acl, 0, entry); // ACL_FIRST_ENTRY
      if (result == 0) {
        throw FileSystemException('Credential extended ACL is unsafe');
      }
      if (result != -1 || errno != 22) fail('inspect credential ACL entry');
    } finally {
      // The entry is borrowed from acl; only its output slot is ours to free.
      calloc.free(entry);
      if (_aclFree(acl) != 0) fail('release credential ACL');
    }
  }

  void validate(int fd, {required bool directory}) {
    // Only verified prefix fields are decoded. Oversized aligned storage avoids
    // relying on the size/timestamps of struct stat across libc/ABI versions.
    // Sources: bionic libc/include/sys/stat.h; glibc bits/struct_stat.h;
    // Darwin sys/stat.h (the 64-bit inode ABI, shared by x64 and arm64).
    final buffer = calloc<Uint64>(32);
    try {
      if (_fstat(fd, buffer.cast()) != 0) fail('inspect credential handle');
      final bytes = ByteData.sublistView(buffer.cast<Uint8>().asTypedList(256));
      final x64 =
          Abi.current() == Abi.linuxX64 || Abi.current() == Abi.androidX64;
      final mode = _mac
          ? bytes.getUint16(4, Endian.host)
          : bytes.getUint32(x64 ? 24 : 16, Endian.host);
      final links = _mac
          ? bytes.getUint16(6, Endian.host)
          : x64
          ? bytes.getUint64(16, Endian.host)
          : bytes.getUint32(20, Endian.host);
      final uid = bytes.getUint32(
        _mac
            ? 16
            : x64
            ? 28
            : 24,
        Endian.host,
      );
      if (uid != _uid() ||
          (mode & 0xf000) != (directory ? 0x4000 : 0x8000) ||
          (mode & 0xfff) != (directory ? 0x1c0 : 0x180) ||
          (!directory && links != 1)) {
        throw FileSystemException(
          'Credential owner, type, links or permissions are unsafe',
        );
      }
      if (_mac) _validateMacAcl(fd);
    } finally {
      calloc.free(buffer);
    }
  }
}
