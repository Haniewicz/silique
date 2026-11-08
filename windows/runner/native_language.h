#ifndef RUNNER_NATIVE_LANGUAGE_H_
#define RUNNER_NATIVE_LANGUAGE_H_

#include <string_view>

namespace silique {
// Presentation only: never use this preference for storage/update admission.
inline bool IsPolishInterfaceLanguage(std::string_view value) {
  const auto first = value.find_first_not_of(" \t\n\r\f\v");
  if (first == std::string_view::npos) return false;
  const auto last = value.find_last_not_of(" \t\n\r\f\v");
  return value.substr(first, last - first + 1) == "pl";
}

inline const wchar_t* WindowsInstanceMessage(bool polish) {
  return polish
      ? L"Silique jest ju\u017c uruchomione albo trwa aktualizacja. Zamknij poprzedni\u0105 instancj\u0119 lub poczekaj na zako\u0144czenie instalatora."
      : L"Silique is already running or an update is in progress. Close the previous instance or wait for the installer to finish.";
}

inline const char* WindowsUpdateDirectoryMessage(bool polish) {
  return polish ? u8"Nie mo\u017cna zabezpieczy\u0107 katalogu aktualizacji."
                : "Cannot secure the update folder.";
}
}  // namespace silique

#endif  // RUNNER_NATIVE_LANGUAGE_H_
