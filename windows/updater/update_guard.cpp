// Wait-only asInvoker process. Never launches a process, shell or elevated
// helper. Holds inherited locks BEFORE UAC, through app exit and real Inno exit.
#include "guard_protocol.h"
#include <windows.h>
#include <cstdint>
#include <cwchar>
#include <vector>
namespace {
// A connection, ACK, pipe disconnect or bootstrap exit is never consumption.
// Only the lifetime of an authenticated high-integrity local client qualifies.
bool HighIntegrityClient(HANDLE pipe) {
  if (!ImpersonateNamedPipeClient(pipe)) return false;
  HANDLE token = nullptr;
  bool ok = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token) != FALSE;
  DWORD length = 0;
  if (ok) GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &length);
  std::vector<BYTE> buffer(length);
  if (ok) ok = length && GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), length, &length);
  if (ok) {
    const auto sid = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data())->Label.Sid;
    const auto count = *GetSidSubAuthorityCount(sid);
    ok = count && *GetSidSubAuthority(sid, count - 1) >= SECURITY_MANDATORY_HIGH_RID;
  }
  if (token) CloseHandle(token);
  if (!RevertToSelf()) ExitProcess(4); // never continue impersonated
  return ok;
}
bool Transfer(HANDLE pipe, HANDLE cancel, void* data, DWORD length, bool write) {
  OVERLAPPED operation{}; operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!operation.hEvent) return false;
  DWORD bytes = 0;
  BOOL ok = write ? WriteFile(pipe, data, length, &bytes, &operation) : ReadFile(pipe, data, length, &bytes, &operation);
  if (!ok && GetLastError() == ERROR_IO_PENDING) {
    HANDLE wait[]{cancel, operation.hEvent};
    ok = WaitForMultipleObjects(2, wait, FALSE, 5000) == WAIT_OBJECT_0 + 1 &&
        GetOverlappedResult(pipe, &operation, &bytes, FALSE);
  }
  if (!ok) { CancelIoEx(pipe, &operation); GetOverlappedResult(pipe, &operation, &bytes, TRUE); }
  CloseHandle(operation.hEvent); return ok && bytes == length;
}
void RetainUntilCancellation(HANDLE cancel) { WaitForSingleObject(cancel, INFINITE); }
}
int wmain(int argc, wchar_t** argv) {
  if (argc < 6 || argc > 512) return 2;
  std::vector<HANDLE> handles;
  for (int i = 1; i < argc; ++i) {
    wchar_t* end = nullptr; const auto value = _wcstoui64(argv[i], &end, 10);
    if (!value || !end || *end || value > UINTPTR_MAX) return 2;
    const auto handle = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(value)); DWORD flags = 0;
    if (!GetHandleInformation(handle, &flags) || !(flags & HANDLE_FLAG_INHERIT)) return 2;
    handles.push_back(handle);
  }
  const HANDLE pipe = handles[0], cancel = handles[1], ready = handles[2], parent = handles[3];
  if (GetFileType(pipe) != FILE_TYPE_PIPE || !SetEvent(ready)) return 2;
  for (;;) {
    OVERLAPPED connect{}; connect.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!connect.hEvent) { RetainUntilCancellation(cancel); break; }
    bool connected = ConnectNamedPipe(pipe, &connect) != FALSE;
    if (!connected) {
      const auto error = GetLastError();
      if (error == ERROR_PIPE_CONNECTED) connected = true;
      else if (error == ERROR_IO_PENDING) {
        HANDLE wait[]{cancel, connect.hEvent};
        if (WaitForMultipleObjects(2, wait, FALSE, INFINITE) == WAIT_OBJECT_0) {
          CancelIoEx(pipe, &connect); DWORD ignored = 0; GetOverlappedResult(pipe, &connect, &ignored, TRUE);
          CloseHandle(connect.hEvent); break;
        }
        DWORD ignored = 0; connected = GetOverlappedResult(pipe, &connect, &ignored, FALSE) != FALSE;
      }
    }
    CloseHandle(connect.hEvent);
    if (!connected) { RetainUntilCancellation(cancel); break; }
    BYTE hello = 0;
    if (!Transfer(pipe, cancel, &hello, 1, false) || hello != silique::kGuardHello || !HighIntegrityClient(pipe)) {
      DisconnectNamedPipe(pipe);
      if (WaitForSingleObject(cancel, 0) == WAIT_OBJECT_0) break;
      continue; // unauthenticated callers can at most deny service, not unlock
    }
    ULONG pid = 0;
    if (!GetNamedPipeClientProcessId(pipe, &pid) || !pid) { RetainUntilCancellation(cancel); break; }
    // The elevated client duplicates its OWN process handle into us. Opening
    // its process as the original standard user fails for over-the-shoulder
    // UAC. A PID alone is neither authority nor a safe lifetime reference.
    DWORD remote = 0;
    if (!Transfer(pipe, cancel, &remote, sizeof(remote), false) || !remote) {
      RetainUntilCancellation(cancel); break;
    }
    HANDLE consumer = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(remote));
    if (GetProcessId(consumer) != pid || WaitForSingleObject(consumer, 0) == WAIT_FAILED) {
      RetainUntilCancellation(cancel); break;
    }
    // Inno must not reach any replacement until the original app has exited.
    HANDLE wait[]{cancel, consumer, parent};
    const auto state = WaitForMultipleObjects(3, wait, FALSE, INFINITE);
    if (state == WAIT_OBJECT_0 + 2) {
      BYTE ack = silique::kGuardAcknowledged;
      Transfer(pipe, cancel, &ack, 1, true);
      // Even failed ACK or early pipe close does not release before process exit.
      HANDLE finish[]{cancel, consumer};
      WaitForMultipleObjects(2, finish, FALSE, INFINITE);
    } else if (state != WAIT_OBJECT_0 && state != WAIT_OBJECT_0 + 1) {
      RetainUntilCancellation(cancel);
    }
    CloseHandle(consumer); break;
  }
  for (auto handle : handles) CloseHandle(handle);
  return 0;
}
