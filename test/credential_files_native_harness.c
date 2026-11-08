/* Linux-only real-native fault harness; never linked into the application.
 * Build/run from the repository (use the session scratch, not /tmp):
 * cc -shared -fPIC -Wall -Wextra -Werror -o "$TMPDIR/credential_faults.so" \
 *   test/credential_files_native_harness.c -ldl
 * SILIQUE_NATIVE_FAULTS=1 LD_PRELOAD="$TMPDIR/credential_faults.so" \
 *   flutter test --no-pub test/credential_files_test.dart
 * Only synthetic tests create the marker files; no credential bytes are read.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int marked(int fd, const char *marker, int parent) {
  const char *enabled = getenv("SILIQUE_NATIVE_FAULTS");
  if (!enabled || strcmp(enabled, "1")) return 0;
  char descriptor[64];
  char path[PATH_MAX];
  snprintf(descriptor, sizeof descriptor, "/proc/self/fd/%d", fd);
  ssize_t length = readlink(descriptor, path, sizeof path - 1);
  if (length <= 0) return 0;
  path[length] = '\0';
  if (parent) {
    char *slash = strrchr(path, '/');
    if (!slash || strncmp(slash + 1, ".pending-", 9)) return 0;
    *slash = '\0';
  }
  const char *slash = strrchr(path, '/');
  if (!slash || strcmp(slash, "/credentials")) return 0;
  size_t size = strlen(path);
  if (size + strlen(marker) + 2 >= sizeof path) return 0;
  path[size++] = '/';
  strcpy(path + size, marker);
  return access(path, F_OK) == 0;
}

int fsync(int fd) {
  if (marked(fd, ".fail-fsync", 1)) {
    errno = EIO;
    return -1;
  }
  static int (*real_fsync)(int);
  if (!real_fsync) *(void **)(&real_fsync) = dlsym(RTLD_NEXT, "fsync");
  if (!real_fsync) { errno = ENOSYS; return -1; }
  return real_fsync(fd);
}

int renameat(int from_fd, const char *from, int to_fd, const char *to) {
  if (marked(from_fd, ".fail-rename", 0)) {
    errno = EIO;
    return -1;
  }
  static int (*real_renameat)(int, const char *, int, const char *);
  if (!real_renameat) *(void **)(&real_renameat) = dlsym(RTLD_NEXT, "renameat");
  if (!real_renameat) { errno = ENOSYS; return -1; }
  return real_renameat(from_fd, from, to_fd, to);
}

/* Linux-hosted Darwin ACL contract facade, NOT a macOS integration test.
 * Apple Libc include/sys/acl.h and posix1e/acl_entry.c specify:
 * ACL_TYPE_EXTENDED=0x100, ACL_FIRST_ENTRY=0, entry found => 0,
 * empty ACL => -1/EINVAL (unlike Linux libacl's 1/0 convention).
 * Only the standalone Dart validation probe calls these exports; the preload
 * fault tests above keep using the host's real stat and filesystem functions.
 */
static int acl_scenario;
static int acl_allocations;
void silique_acl_scenario(int scenario) { acl_scenario = scenario; }
int silique_acl_allocations(void) { return acl_allocations; }
int *silique_darwin_errno(void) { return &errno; }

int silique_darwin_fstat(int fd, void *buffer) {
  if (fd != 73 && fd != 74) { errno = EBADF; return -1; }
  uint16_t mode = (fd == 74) ? 0040700 : 0100600;
  uint16_t links = 1;
  uint32_t uid = geteuid();
  memset(buffer, 0, 256);
  memcpy((char *)buffer + 4, &mode, sizeof mode);
  memcpy((char *)buffer + 6, &links, sizeof links);
  memcpy((char *)buffer + 16, &uid, sizeof uid);
  return 0;
}

void *acl_get_fd_np(int fd, int type) {
  if ((fd != 73 && fd != 74) || type != 0x100) {
    errno = EINVAL;
    return NULL;
  }
  if (acl_scenario == 2) { errno = EIO; return NULL; }
  /* Darwin filesec_get_property(FILESEC_ACL) reports an absent ACL this way. */
  if (acl_scenario == 4) { errno = ENOENT; return NULL; }
  void *acl = malloc(1);
  if (acl) acl_allocations++;
  return acl;
}

int acl_get_entry(void *acl, int entry_id, void **entry) {
  if (!acl || entry_id != 0) { errno = EINVAL; return -1; }
  if (acl_scenario == 3) { errno = EIO; return -1; }
  if (acl_scenario == 0) { errno = EINVAL; return -1; }
  *entry = acl; /* borrowed: must NOT be separately freed */
  return 0;
}

int acl_free(void *acl) {
  if (!acl) { errno = EINVAL; return -1; }
  free(acl);
  acl_allocations--;
  return 0;
}
