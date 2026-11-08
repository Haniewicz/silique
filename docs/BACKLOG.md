# Planowane i wykonane zmiany

Wpisy rozróżniają zadania planowane od wykonanych. **Nie implementuj zadań
planowanych bez wyraźnego polecenia**. Ukończonych pozycji nie traktuj jako
niewdrożonych; stan publikacji sprawdzaj w `docs/HANDOFF.md` i na GitHubie.
Brak osobistego testu właściciela nie oznacza braku implementacji lub publikacji.

## 1. Android: usunąć wybór miejsca przechowywania poświadczeń

Status: **zaimplementowane dla 0.2.29+38** na jawne polecenie właściciela.
Nowe instalacje: Keystore; brak selektorów. Dotychczasowy lokalny magazyn:
jednorazowa jawna oferta, odmowa zapamiętana bez zmiany kluczy, akceptacja
przez istniejący bezpieczny kontroler migracji. Test prawdziwego SQLite
zachowuje klucz, tożsamość, nieaktywne konto i ukryte notatki.
Nie wykonano testu na fizycznym Androidzie. [Wydanie i dowody](0.2.29.md).

Poniżej zachowany pierwotny kontrakt decyzji właściciela z 2026-10-26.

Na Androidzie Keystore nigdy nie prosi o hasło, więc opcja „lokalny plik
(mniej bezpieczny)” nie daje żadnej korzyści, a jest słabsza od Keystore — i to
właśnie ta ścieżka spowodowała błąd startu w 0.2.27 (`EACCES`, errno 13).

Pierwotne kryteria (zrealizowane w powyższym zakresie):

- ukryć wybór trybu na Androidzie w pierwszej konfiguracji (`lib/ui/location_setup.dart`)
  i w Ustawieniach (`lib/ui/dialogs.dart`, `lib/ui/credential_mode_picker.dart`),
  zawsze używać magazynu systemowego;
- instalacje będące już w trybie lokalnym (0.2.27/0.2.28) nie mogą stracić danych:
  przy starcie jednorazowa propozycja migracji do magazynu systemowego z istniejącą,
  przetestowaną ścieżką — bez cichego przełączania i bez kasowania czegokolwiek;
- macOS, Linux i Windows bez zmian;
- testy: brak selektora na Androidzie, wymuszony tryb systemowy, migracja
  lokalny → systemowy na prawdziwym notatniku.

## 2. Windows: aktualizacja z poziomu aplikacji

Status: **wykonane i opublikowane w 0.2.32+41**.
[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.32).
[Implementacja, testy i ograniczenia](0.2.32.md); bieżąca proweniencja:
[HANDOFF.md](HANDOFF.md).

Zrealizowano:

- jawne sprawdzanie, pobieranie i uruchamianie aktualizacji w Ustawieniach
  rozpoznanej instalacji Windows;
- weryfikację podpisanego manifestu, rozmiaru i SHA-256 oraz tożsamości
  istniejącej instalacji; natywne blokady plików przez przekazanie do Inno Setup;
- końcowy zapis notatek, zablokowanie nowych mutacji, opróżnienie operacji
  i checkpoint przed zamknięciem aplikacji;
- aktualizację w miejscu, także chronionego niestandardowego katalogu,
  z zachowaniem istniejących danych, kluczy i ustawień;
- natywne testy Windows i rzeczywistego Inno Setup; końcowe buildy i publikacja
  zakończone sukcesem. Publiczny kanał wskazuje 0.2.32/build 41.

Ograniczenia i weryfikacja urządzenia (nie ponowna implementacja zadania):

- pierwsze przejście ze starszego klienta wymaga ręcznej instalacji Setup 0.2.32;
- ZIP portable i stare lub nierozpoznane instalacje pozostają ręczne;
- brak osobistego testu właściciela, interaktywnego UAC i UAC z innym
  administratorem; testy runnera nie potwierdzają tych scenariuszy;
- brak Authenticode: Windows może pokazać nieznanego wydawcę. Nie omijać ochrony
  systemowej; po instalacji uruchomić Silique ze zwykłego skrótu.
