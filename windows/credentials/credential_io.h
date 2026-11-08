#ifndef SILIQUE_CREDENTIAL_IO_H_
#define SILIQUE_CREDENTIAL_IO_H_
#include <windows.h>
#ifdef SILIQUE_CREDENTIAL_EXPORTS
#define SILIQUE_CREDENTIAL_API __declspec(dllexport)
#else
#define SILIQUE_CREDENTIAL_API __declspec(dllimport)
#endif
// Capture TLS errors before returning across FFI. Never infer absence from a
// separate Dart GetLastError call: VM activity can overwrite that thread slot.
extern "C" {
SILIQUE_CREDENTIAL_API HANDLE SiliqueCredentialOpen(const wchar_t* name, DWORD access,
    DWORD share, SECURITY_ATTRIBUTES* security, DWORD creation, DWORD flags,
    HANDLE template_file, DWORD* error);
SILIQUE_CREDENTIAL_API BOOL SiliqueCredentialMkdir(const wchar_t* name,
    SECURITY_ATTRIBUTES* security, DWORD* error);
SILIQUE_CREDENTIAL_API BOOL SiliqueCredentialLock(HANDLE file, DWORD flags,
    DWORD reserved, DWORD low, DWORD high, OVERLAPPED* overlapped, DWORD* error);
}
#endif
