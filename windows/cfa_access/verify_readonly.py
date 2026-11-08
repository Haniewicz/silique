"""Read-only smoke checks. Never invokes --request or an elevated --apply.

Usage: python verify_readonly.py <helper.exe> <existing-root>
A real silique.exe must already be alongside helper.exe (a scratch copy is fine).
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys


def require_unelevated() -> None:
    if os.name != "nt":
        raise RuntimeError("Windows only")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    token = wintypes.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        elevation = wintypes.DWORD()
        size = wintypes.DWORD()
        if not advapi.GetTokenInformation(token, 20, ctypes.byref(elevation), ctypes.sizeof(elevation), ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        if elevation.value:
            raise RuntimeError("REFUSED: smoke test must run without elevation; no helper was started")
    finally:
        kernel.CloseHandle(token)


def main() -> None:
    helper, root = (Path(argument).resolve(strict=True) for argument in sys.argv[1:])
    sibling = helper.with_name("silique.exe")
    if not sibling.is_file() or not root.is_dir():
        raise RuntimeError("Real sibling executable and existing root required")
    require_unelevated()
    print("TokenIsElevated=0; no UAC and no Defender preference commands will be run.")
    checks = [
        (["--inspect", str(root)], {"confirmed", "unconfirmed"}, 0),
        (["--apply"], {"failed"}, 0x534903),
        (["--apply", "--target", "C:\\not-the-sibling.exe"], {"failed"}, 1),
        (["--inspect", "\\\\localhost\\C$\\Windows"], {"failed"}, 1),
        (["--inspect", str(root) + "\\*"], {"failed"}, 1),
    ]
    for arguments, statuses, expected_exit in checks:
        # Check again immediately before every invocation, not only at startup.
        require_unelevated()
        completed = subprocess.run([str(helper), *arguments], capture_output=True, text=True, encoding="utf-8", timeout=20)
        print(json.dumps({"command": [str(helper), *arguments], "exit": completed.returncode,
                          "stdout": completed.stdout.strip(), "stderr": completed.stderr}, ensure_ascii=True))
        result = json.loads(completed.stdout)
        assert set(result) == {"status", "executable", "message", "canRequest"}, result
        # Only a confirmed protected install may carry the request capability.
        assert result["canRequest"] is (result["status"] == "confirmed"), result
        assert result["status"] in statuses, result
        assert os.path.normcase(result["executable"]) == os.path.normcase(str(sibling)), result
        assert completed.returncode == expected_exit, completed.returncode
        assert not completed.stderr, completed.stderr
    print("PASS 5 CLI smoke checks; no live UAC, no elevated operation.")


if __name__ == "__main__":
    main()
