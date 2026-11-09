# Silique

## Co działa

- Lokalna praca bez konta, autosave, wiele vaultów, foldery, przypięcia, tagi, kosz i przywracanie. Start w ostatnim vaulcie, import całych folderów Markdown/TXT z zachowaniem hierarchii i natywne przyciski okna.
- Edytor LiveMD z podglądem na żywo, tryb źródłowy Markdown, formatowanie, wiki-linki, import/eksport .md.
- Dziennik z deterministycznym identyfikatorem dla każdego dnia; wyszukiwanie tytułu, treści i folderu z fragmentem kontekstu.
- Własny serwer, konta, zaproszenia, logowanie/wylogowanie, lista i unieważnianie urządzeń.
- AES-256-GCM E2EE, oddzielne klucze konta i vaultów, vaulty z dodatkowym hasłem Argon2id oraz klucze odzyskiwania.
- Parowanie X25519 po porównaniu kodów na obu urządzeniach.
- Trwała kolejka offline, idempotentne batche, odzyskiwanie po utracie potwierdzenia, three-way merge i kopie konfliktowe.
- Windows budowany ręcznie na standardowym runnerze GitHub Actions w publicznym repozytorium instalatorów, z pobraniem prywatnych źródeł. macOS i Android powstają lokalnie, Linux GTK4 na osobnym builderze. Android ma stały klucz wydania. Publiczne instalatory i podpisane kanały aktualizacji są w osobnym [repozytorium dystrybucji](https://github.com/Haniewicz/silique-releases); kod pozostaje prywatny.

## Uruchomienie

Flutter **3.47.7**, Dart **3.13.5**:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos   # albo windows, urządzenie Android
```

macOS wymaga Xcode. Linux GTK4 korzysta z osobnego SDK i runnera — [budowanie DEB i RPM](docs/desktop-packages.md). Uruchomienie wymaga GTK4 >= 4.14, glibc >= 2.39, libsecret i działającego Secret Service. Brak magazynu sekretów jest błędem, nie przechodzimy na jawne przechowywanie kluczy. Android: SDK i Java 17. Wydanie APK wymaga klucza — [budowanie wydań](docs/releases.md).

Na tej stacji Flutter, JDK 17 i Android SDK są przygotowane w `~/.local/share/silique-toolchains/`. Xcode 27.1 i CocoaPods są dostępne lokalnie. `Zbuduj Android.command` tworzy podpisany APK. `Zbuduj macOS.command` tworzy ZIP w `packages/` i aktualizuje jedną instalację `/Applications/Silique.app`; po udanej instalacji usuwa rozpakowane kopie Release/Debug. `Uruchom Silique.command` wykonuje tę samą aktualizację i otwiera aplikację z Programów. Przed aktualizacją zamknij Silique. Vaulty i klucze pozostają zachowane; archiwów ZIP nie rozpakowujemy do katalogów projektu. Wersja 0.2.0 została zbudowana lokalnie na Androida i macOS; podpisy przeszły walidację. Aktualne opublikowane paczki: [publiczne wydanie 0.2.8](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.8), build 17, po potwierdzeniu właściciela. [Zmiany i wyniki weryfikacji](docs/0.2.8.md). Poprawka zmniejsza liczbę odczytów pęku kluczy macOS, zachowuje stare wpisy podczas migracji i pokazuje postęp otwierania. Po odblokowaniu Actions Windows 0.2.5+10 przeszedł kompilację, test magazynu kluczy i SQLite oraz instalację, uruchomienie i deinstalację EXE. Wydanie 0.2.5+10 obejmuje wszystkie platformy, w tym DEB i RPM na GTK4; opublikowano je po potwierdzeniu właściciela.

## Pierwsze użycie

1. Wybierz miejsce przechowywania vaultów. „Rozpocznij lokalnie” tworzy vault Osobiste i jedną edytowalną notatkę powitalną.
2. Ustawienia → adres własnego serwera → logowanie albo rejestracja (jeśli dozwolona).
3. Zapisz klucz odzyskiwania konta. Serwer nie zna jego jawnej postaci.
4. Włącz synchronizację wybranych vaultów.
5. Na drugim urządzeniu użyj klucza odzyskiwania lub parowania i porównaj pełne kody. Chronione vaulty wymagają dodatkowo własnego hasła.

[Architektura i bezpieczeństwo](docs/architecture.md) · [Testy](docs/testing.md) · Backend: `Haniewicz/silique-self-hosted`.

Opublikowana wersja 0.2.7+12 obejmuje wszystkie platformy i pozostaje wydaniem testowym. Updater macOS/Android oraz instalatory Windows/Linux GTK4 są dostępne od 0.2.5. macOS/Windows wymagają docelowego podpisania i notarizacji przed szerszą dystrybucją. Zdjęcia PNG, JPEG, GIF, WebP i BMP można przeciągać do edytora albo wybierać przyciskiem. Wersja 0.2.2 usuwa limit 600 kB: oryginały są przechowywane jako osobne załączniki E2EE i przesyłane w częściach. Limit 1 MB dotyczy tekstu notatki, a zdjęcia go nie zużywają. Nie ma pełnej rotacji przejętych kluczy ani interfejsu webowego. Od 0.2.5 macOS/Android wykrywają aktualizacje automatycznie, a instalację potwierdza użytkownik. Od 0.2.7 także Linux RPM/DEB sprawdza aktualizacje i instaluje je po potwierdzeniu oraz systemowej autoryzacji. Windows i portable Linux wymagają ręcznej aktualizacji. Kod: [PolyForm Noncommercial License 1.0.0](LICENSE) — użytek osobisty, badawczy, edukacyjny i charytatywny; użytek komercyjny wymaga osobnej licencji od właściciela.

[Zmiana nazwy na Silique i zgodność istniejących danych](docs/rebrand.md).


## Zmiany 0.2.1

Menu notatek i folderów otwiera prawy przycisk myszy lub dłuższe przytrzymanie. Notatki można otwierać i zamykać w kartach, a Ctrl+F / Cmd+F wyszukuje treść aktywnej notatki. Toolbar pozwala ustawić rozmiar tekstu edytora (8–72 px) i wstawić zdjęcie. Podczas wpisywania `[[` pojawiają się propozycje istniejących notatek. Adresy HTTP/HTTPS są formatowane i klikalne.

W selektorze vaultów jest „Zarządzaj vaultami”: tworzenie, wybór i zmiana nazwy. „Miejsce zapisu i przenoszenie danych” przenosi wspólny magazyn wszystkich lokalnych vaultów do pustego katalogu na komputerze. Kopia źródłowa pozostaje do odzyskania danych; nowa lokalizacja obowiązuje także po restarcie. macOS zachowuje dostęp do wybranego katalogu przez security-scoped bookmark. Klucze pozostają w systemowym magazynie sekretów, więc przeniesienie katalogu na inny komputer nie zastępuje odzyskiwania konta/vaulta.

Kosz oferuje trwałe usuwanie po potwierdzeniu. Dla wcześniej synchronizowanego vaulta wymagane są połączenie z kontem właściciela, włączona synchronizacja i zaktualizowany serwer z endpointem DELETE notatki. Serwer usuwa historię i rozsyła identyfikator usunięcia, blokując ponowne przesłanie starej kopii. Usunięcie nie obejmuje kopii zapasowych ani urządzeń, które pozostają offline. Stare klienty wymagają aktualizacji, aby odbierać trwałe usunięcia.

Status lokalnego vaulta nie pokazuje już E2EE po synchronizacji innego vaulta. Lista urządzeń ładuje się przy otwarciu ustawień, zachowuje ostatni wynik po zamknięciu panelu i odświeża się ponownie po otwarciu.

Zmiany renderowania i automatyczne linki korzystają z lokalnej kopii livemd_flutter 0.6.0 w `vendor/livemd_flutter`; zachowano licencję upstream. Kursor używa równomiernego odstępu linii, checkboxy mają rozmiar zależny od tekstu i wyśrodkowaną zawartość.


## Zdjęcia w 0.2.2

Przeciągnij jeden lub kilka plików na treść notatki. Podświetlenie wskazuje miejsce odbioru; zdjęcia trafiają do pozycji upuszczenia, również w trybie źródłowym Markdown. Obsługiwane są PNG, JPEG, GIF, WebP i BMP. Nie ma aplikacyjnego limitu wielkości pojedynczego zdjęcia; dostępne miejsce i pamięć urządzenia nadal ograniczają możliwości pracy. Oryginalne bajty pozostają zachowane, a podgląd jest dekodowany do maksymalnie 1600 px szerokości.

Manifesty i fragmenty załączników są szyfrowane kluczem vaulta zarówno lokalnie, jak i na serwerze. Synchronizacja pobiera zdjęcia do pracy offline. Przerwane przesyłanie można ponowić po ponownym uruchomieniu aplikacji. Usunięcie notatki z kosza usuwa też jej zdjęcia; obrazy nadal używane przez inne notatki lub ich historię pozostają do czasu usunięcia ostatniego odniesienia. Eksport Markdown osadza zdjęcia w pliku. Starsze obrazy zapisane jako data URI nadal działają.

Wymagany jest serwer z obsługą `image_attachments` (0.2.2); starszy serwer nie przyjmie nowych załączników, a klient zachowa je lokalnie. Przeciąganie opiera się na desktop_drop 0.8.4, zgodnym z używanymi wersjami cross_file/share_plus; integrację i zabezpieczony dostęp do plików macOS sprawdza lokalna kompilacja.

## Podgląd zdjęć w 0.2.3

Zdjęcia z długimi nazwami i identyfikatorami załączników wyświetlają się jako obrazy także w wąskim edytorze. Poprawka obejmuje już zapisane notatki bez ponownego importowania plików. Szczegóły: [0.2.3](docs/0.2.3.md).


## Zmiany 0.2.4

Wielozaznaczanie i akcje grupowe, podfoldery z rozwijanym drzewem, przeciąganie notatek i folderów, wybór lokalizacji przy pierwszym uruchomieniu oraz zmiana miejsca w ustawieniach. Status synchronizacji jest na dolnym pasku; nazwę bieżącego urządzenia można zmienić globalnie. Wyszukiwanie podświetla wyniki w obu trybach, a rozmiar px formatuje tylko zaznaczenie. Menu „…” otwiera się przy folderze. Szczegóły i ograniczenia: [0.2.4](docs/0.2.4.md).

## Wydanie 0.2.5 — aktualizacje i instalatory

Automatyczne sprawdzanie dostępności nowych wersji, ręczne sprawdzanie w ustawieniach oraz instalacja po potwierdzeniu użytkownika. macOS używa Sparkle, Android systemowego instalatora APK. Podpisane metadane i paczki pochodzą z publicznego repozytorium bez konta GitHub. Pierwszą wersję z updaterem trzeba zainstalować ręcznie. Windows otrzymuje instalator EXE i ZIP, Linux GTK4 paczki DEB, RPM dla Fedory oraz tar.gz; Windows i Linux z tar.gz pozostają ręczne; od 0.2.7 RPM/DEB mogą aktualizować się z aplikacji po systemowej autoryzacji. [Budowanie i weryfikacja](docs/desktop-packages.md). Wydanie opublikowano 2026-10-21 po potwierdzeniu właściciela. [Działanie i publikowanie](docs/updater.md).
