#include "windows/runner/native_language.h"

#include <cassert>
#include <iostream>
#include <string>

int main() {
  using silique::IsPolishInterfaceLanguage;
  assert(!IsPolishInterfaceLanguage(""));
  assert(!IsPolishInterfaceLanguage("en"));
  assert(IsPolishInterfaceLanguage("pl"));
  assert(IsPolishInterfaceLanguage(" \t\r\npl\n"));
  for (const auto invalid : {"PL", "de", "pl-PL", "pl arbitrary", "en pl"}) {
    assert(!IsPolishInterfaceLanguage(invalid));
  }
  assert(!IsPolishInterfaceLanguage(std::string("pl\0", 3)));
  assert(!IsPolishInterfaceLanguage(std::string(100000, 'p')));
  assert(std::wstring(silique::WindowsInstanceMessage(false)).find(L"already running") != std::wstring::npos);
  assert(std::wstring(silique::WindowsInstanceMessage(true)).find(L"Silique jest") == 0);
  assert(std::string(silique::WindowsUpdateDirectoryMessage(false)) == "Cannot secure the update folder.");
  assert(std::string(silique::WindowsUpdateDirectoryMessage(true)) == u8"Nie mo\u017cna zabezpieczy\u0107 katalogu aktualizacji.");
  std::cout << "Portable Windows language probe passed\n";
}
