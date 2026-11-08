# Testy

`flutter analyze` i `flutter test` obejmują AEAD/AAD, rozdzielenie haseł, brak jawnej treści chronionego vaulta na dysku, odzyskiwanie, restart i trwałą kolejkę, three-way merge, wyszukiwanie po treści, autosave, dziennik oraz układ 320/390/780/1380 px.

Test kontraktu dwóch klientów z prawdziwym serwerem (osobna, jednorazowa baza, rejestracja public):

```sh
SILIQUE_TEST_SERVER=http://127.0.0.1:18788 flutter test test/sync_integration_test.dart
```

Sprawdza szyfrowaną synchronizację i odzyskanie konta na drugim urządzeniu, równoległe zmiany, kopie konfliktowe, edycję kontra usunięcie oraz utratę odpowiedzi po udanym zapisie i restart klienta. Serwer testowy musi pochodzić z repo silique-server. Domyślny przebieg pomija ten test, jeśli nie podano adresu.

Testy repozytorium używają małych parametrów Argon2id wyłącznie dla szybkości. Produkcyjny adapter zawsze stosuje 64 MiB i 3 iteracje oraz wykonuje KDF w osobnym izolacie. Hasła nie pochodzą z parametrów narzuconych przez serwer.

Widoki wzorcowe w test/goldens są zapisem kontrolnym. Tworzenie nowych obrazów: `SILIQUE_CAPTURE_UI=1 flutter test test/ui_test.dart --update-goldens`. Nie porównujemy automatycznie dynamicznych dat z nieruchomymi obrazami. Testy funkcjonalne zawsze sprawdzają brak błędów layoutu.

Test natywnych adapterów na jednorazowym emulatorze Androida:

```sh
flutter test integration_test/native_storage_test.dart -d emulator-5554
```

Sprawdza rzeczywisty magazyn kluczy systemu, autosave w SQLite, zaszyfrowaną treść chronionego vaulta oraz odczyt po zamknięciu i ponownym otwarciu repozytorium. Tworzy dane testowe, dlatego należy używać osobnego emulatora bez własnych notatek. Opcjonalne `--dart-define=SILIQUE_SMOKE_SERVER=https://notes.example.com` sprawdza rzeczywiste połączenie HTTP z serwerem bez rejestracji konta.

Wprowadzanie tekstu w tym teście kontroluje TestTextInput, aby nie mieszać zdarzeń testowych z klawiaturą emulatora ([wyjaśnienie Fluttera](https://api.flutter.dev/flutter/flutter_test/TestTextInput/enterText.html)). Magazyn kluczy, SQLite, kryptografia i HTTP używają adapterów produkcyjnych. Nie jest to test wszystkich zewnętrznych klawiatur Androida.

2026-10-19: test natywny przeszedł na emulatorze Pixel 7, Android 15 / API 35, ARM64, włącznie z połączeniem przez Tailscale. Standardowy zestaw: 8 testów zaliczonych; dwa testy z prawdziwym serwerem są pomijane bez SILIQUE_TEST_SERVER i zostały uruchomione osobno. Testowano też blokadę kompilacji release bez klucza podpisu oraz możliwość skonfigurowania debug bez tego klucza.

macOS: lokalna kompilacja uniwersalna i walidacja podpisu przeszły. W rzeczywistym oknie sprawdzono onboarding, edycję tytułu, autosave oraz zachowanie zmiany po zamknięciu czerwonym przyciskiem i ponownym uruchomieniu. Dodano oczekiwanie na zapis przy systemowym ⌘Q; ponowna kompilacja przeszła. Scenariusz końcowej paczki potwierdzono ręcznie 2026-10-20, po migracji kluczy (szczegóły poniżej).

Poprawka 0.1.1: 12 testów zaliczonych (dwa serwerowe domyślnie pomijane), analiza bez uwag. Nowe testy sprawdzają migrację i zachowanie starych kluczy, jeden odczyt OS po ponownym otwarciu zbiorczego wpisu, równoległe zapisy bez utraty kluczy, trwałe usunięcie sesji oraz brak resetu po odmowie dostępu, niepotwierdzonym zapisie i uszkodzeniu formatu. Test natywnego podpisu na osobnym wpisie jednorazowym potwierdził, że sam self-signed certyfikat nie usuwa kontroli cdhash po przebudowie; nie zmieniono ustawień zaufania ani ACL istniejących kluczy aplikacji.

Dodatkowy przypadek poprawki: utrata potwierdzenia zapisu klucza nie pozwala nadpisać zapisanego klucza starym stanem pamięci. Zapis Keychain na macOS używa SecItemUpdate bez kasowania poprzedniego wpisu po błędzie.

2026-10-20: końcowy zestaw 12 testów zaliczony; dwa testy z rzeczywistym serwerem uruchomione oddzielnie i oba zaliczone. Końcowe kompilacje macOS/Android 0.1.1+2 oraz weryfikacje podpisów przeszły. Użytkownik potwierdził otwarcie po wcześniejszej migracji; ręczny test szybkiego ⌘Q końcowej paczki przeszedł po zatwierdzeniu zgody macOS.

Potwierdzenie natywne 2026-10-20: w osobnej nowej notatce wpisano tytuł, potwierdzono zmianę w interfejsie, dopisano końcowy znacznik i natychmiast wywołano ⌘Q (cały etap dopisania i zamknięcia trwał około 62 ms, przy autosave 350 ms). Proces zakończył się, a ponownie uruchomiona aplikacja pokazała pełny tytuł ze znacznikiem. Kolejne uruchomienie nie wymagało kolejnej zgody Keychain. Notatka testowa została przeniesiona do kosza; istniejące notatki pozostawiono bez zmian.

Silique 0.2.0: 14 testów lokalnych i 2 integracyjne z rzeczywistym osobnym serwerem zaliczone. Nowy test otwiera poprzedni katalog/pliki, odblokowuje wcześniejszą chronioną notatkę bez zmiany kluczy i sprawdza tożsamość oraz kolejkę. Drugi test odmawia nadpisywania dwóch istniejących katalogów. Zaktualizowano obrazy desktop/Android i sprawdzono markę Silique.

2026-10-20: użytkownik potwierdził odczyt swoich dotychczasowych notatek w rzeczywistej instalacji Silique 0.2.0 na macOS po zgodzie na dostęp do pęku kluczy. Nie przebudowywano paczki po tym potwierdzeniu.
