# Wydania

## Bieżąca polityka paczek macOS

Od 0.2.30 publikujemy DMG zamiast ZIP macOS; jeden obraz służy do ręcznej
instalacji i aktualizacji Sparkle. Nie usuwać historycznych paczek. Przejście
z Mac 0.2.29 lub starszego wymaga jednorazowej ręcznej instalacji. Windows ZIP
pozostaje bez zmian. [Kontrakt](DMG_DISTRIBUTION.md), [wydanie](0.2.30.md).
Pozostałe opisy poniżej zawierają również historyczne procedury.

Windows korzysta z ręcznego workflow w publicznym repozytorium instalatorów na standardowym runnerze GitHub Actions. Źródła są pobierane z prywatnego repozytorium tylko do kompilacji, a logi kompilatora szyfrowane. Po odblokowaniu konta kompilacja i próby instalatora 0.2.5+10 przeszły. macOS i podpisany APK powstają lokalnie, DEB i RPM na GTK4 w osobnym środowisku Linux. [Budowanie i wyniki testów Windows/Linux](desktop-packages.md). Starszy workflow w prywatnym repozytorium pozostaje bez automatycznych wyzwalaczy. Kod pozostaje prywatny; instalatory są dystrybuowane przez osobne publiczne repozytorium bez logowania GitHub.

## Lokalna kompilacja Androida

`Zbuduj Android.command` używa lokalnego Fluttera, JDK 17, Android SDK oraz ignorowanego `android/key.properties`. Zapisuje podpisany APK i SHA256 w `packages/` (poza Gitem). Narzędzia na tym Macu są w `~/.local/share/silique-toolchains/`. Kompilacja nie uruchamia GitHub Actions ani płatnych usług.

Android: w GitHub Secrets ustawiono ANDROID_KEYSTORE_BASE64, ANDROID_STORE_PASSWORD i ANDROID_KEY_PASSWORD. Klucz i hasło kopii właściciela znajdują się poza repozytorium w `/Users/kamil/.local/share/silique-signing/`, z uprawnieniami 0600. Należy je zachować w niezależnej bezpiecznej kopii. Utrata klucza uniemożliwi aktualizację tej samej instalacji APK.

Lokalne `android/key.properties` jest ignorowane przez Git:

```properties
storeFile=silique-release.jks
storePassword=...
keyAlias=silique
keyPassword=...
```

Release nie ma cichego fallbacku na losowy debug signing key. macOS wymaga docelowego Developer ID/notaryzacji, Windows certyfikatu podpisu. Paczki testowe mogą wyświetlać komunikaty systemu o niezweryfikowanym wydawcy. Nie dostarczono cudzych certyfikatów ani nie wyłączono systemowych mechanizmów ochrony.

Publiczna dystrybucja: https://github.com/Haniewicz/silique-releases. Aktualne [wydanie 0.2.8+17](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.8) opublikowano 2026-10-22 po potwierdzeniu właściciela, z kompletem siedmiu paczek i podpisanymi kanałami aktualizacji. [Zmiany i weryfikacja](0.2.8.md). Wersja 0.2.4 została tam skopiowana z zatwierdzonego prywatnego wydania bez zmiany bajtów. Wydanie [0.2.5+10](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.5), opublikowane 2026-10-21 po potwierdzeniu właściciela, obejmuje macOS ZIP, Android APK, Windows EXE/ZIP oraz Linux GTK4 DEB/RPM/tar.gz; wcześniejszy kandydat +9 pozostał oddzielnie. macOS/Android mają podpisany updater: wykrywanie jest automatyczne, pobieranie i instalacja wymagają działania użytkownika. Od 0.2.7 także Linux RPM/DEB obsługuje potwierdzane aktualizacje z aplikacji; przejście z 0.2.6 jest ręczne. Windows i portable Linux pozostają ręczne. Nie używa PAT GitHuba. Pierwsza instalacja wersji z updaterem jest ręczna. [Szczegóły i procedura publikacji](updater.md). Nowe wydanie publikujemy dopiero po osobistym teście i zgodzie właściciela.

## Status 2026-10-19

GitHub zakończył uruchomienia jako startup_failure przed przydzieleniem runnerów: nieudane płatności lub limit wydatków konta. Na życzenie właściciela pominięto płatne budowanie i usunięto wyzwalacze push/pull_request. Pozostał wyłącznie ręczny workflow_dispatch, do świadomego użycia po rozwiązaniu rozliczeń. Paczki z GitHub Actions nie zostały zbudowane. Lokalna kompilacja pozostaje dostępna.

Lokalnie zbudowano podpisany uniwersalny APK 0.1.0 (versionCode 1), 62,3 MB. Android API 24+, target/compile API 36; ARM64, ARMv7 i x86_64. `apksigner verify` potwierdził podpis APK v2 z RSA 4096. Odcisk SHA256 certyfikatu: `2021902e8c43d5c10059c9f0458ed8c1ac94fce86a488f7b46d0b0eb3467996e`.

SHA256 pliku APK jest dołączony do wydania. Gotowe pliki są dostarczane jako zasoby prywatnego [wydania testowego](https://github.com/Haniewicz/silique-app/releases/tag/v0.1.0-preview.1), bez użycia runnerów Actions.

macOS: zbudowano aplikację 0.1.0, około 53 MB, uniwersalną ARM64/x86_64, minimum macOS 12. `codesign --verify --deep --strict` potwierdza poprawność pakietu. Wydanie 0.1.0 było podpisane ad-hoc, bez Developer ID i notaryzacji Apple. Lokalne budowanie: `Zbuduj macOS.command`; skrypt wskazuje Xcode także wtedy, gdy system domyślnie używa Command Line Tools. Od 2026-10-21 skrypt również podmienia jedną lokalną instalację `/Applications/Silique.app`, sprawdza jej podpis i usuwa robocze kopie Release/Debug. Przed uruchomieniem zamknij aplikację. Archiwa ZIP pozostają w `packages/`; vaulty i klucze nie są zmieniane. Wtyczki tej wersji korzystają ze Swift Package Managera.

Wersje binarne Windows i Linux pozostają do zbudowania na odpowiednich systemach.

## Poprawka 0.1.1 — macOS Keychain (2026-10-20)

Klucze macOS są teraz przechowywane w jednym wpisie `pl.novanotes.keys` / `nova.keys.v1`. Starsze wpisy migrują dopiero po udanym odczycie i potwierdzonym zapisie; pozostają zachowane. Odmowa dostępu lub uszkodzony format nie powoduje resetu kluczy. Usunięta sesja ma trwały znacznik, więc nie wraca ze starego wpisu. Kolejne otwarcie odczytuje jeden wpis systemowy; nie zapisuje ponownie niezmienionych kluczy urządzenia.

Lokalny skrypt macOS używa odtąd własnego certyfikatu z trwałym odciskiem i identyfikatorem aplikacji w wymaganiu podpisu. Materiały podpisu są poza Gitem, w `~/.local/share/silique-signing/macos-preview.*`. Osobny pęk podpisu nie jest dodawany do listy wyszukiwania, a ustawienia zaufania systemu pozostają bez zmian. To podpis testowy, bez Developer ID i notaryzacji.

Sam stały certyfikat nie gwarantuje braku pytań po aktualizacji: test dwóch kompilacji wykazał dodatkową kontrolę cdhash w macOS. Po zmianie paczki może być potrzebna jedna zgoda na zbiorczy wpis. Pierwsza migracja wymaga zgód na starsze wpisy (w tym lokalny klucz i tożsamość urządzenia). W oknie systemowym „Zawsze pozwalaj” zapamiętuje zgodę dla danej wersji i danego wpisu. Nie rozszerzamy dostępu do wszystkich aplikacji. [Zasady podpisów i dostępu do Keychain opisuje Apple](https://developer.apple.com/library/archive/technotes/tn2206/).

Start aplikacji pokazuje teraz oczekiwanie na systemowy magazyn zamiast pustego okna. Testy poprawki: 12 zaliczonych, dwa testy serwerowe pominięte bez skonfigurowanego serwera. Analiza Fluttera bez uwag. Użytkownik potwierdził otwarcie aplikacji po migracji starych wpisów. Końcowy test tej paczki na macOS zakończono 2026-10-20: dopisanie ostatnich znaków i natychmiastowe ⌘Q zachowało pełny tytuł po ponownym uruchomieniu. Kolejne uruchomienia tej samej paczki nie wyświetliły dodatkowych pytań o klucze. Własną notatkę testową przeniesiono następnie do kosza.

Zapis zbiorczego wpisu używa natywnego SecItemUpdate; tworzy wpis wyłącznie przy errSecItemNotFound i nigdy nie usuwa poprzedniego wpisu po nieudanej aktualizacji. Po utracie potwierdzenia klient odczytuje stan systemowy przed kolejnym zapisem.

Końcowe pliki: [prywatne wydanie 0.1.1](https://github.com/Haniewicz/silique-app/releases/tag/v0.1.1-preview.1), Android versionCode 2, macOS build 2. Walidacja podpisów obu paczek przeszła. Dwa testy integracyjne z rzeczywistym serwerem uruchomiono ponownie 2026-10-20 na osobnej bazie i oba przeszły, łącznie z parowaniem oraz odzyskaniem po utracie potwierdzenia. Automatyczne/płatne budowanie pozostaje wyłączone.

## Silique 0.2.0 (2026-10-20)

Zmieniono markę, nazwy repozytoriów, interfejs, paczki, katalog projektu i serwer LXC CT 100. Zasady identyfikatorów zgodności i przeniesienia danych opisuje [rebrand](rebrand.md). Zestaw: 14 testów lokalnych (w tym migracja zaszyfrowanych danych), dwa dodatkowe testy integracyjne z serwerem, trzy testy widoków z odświeżonymi obrazami oraz czysta analiza. Serwer ma 8 zaliczonych testów, działającą kopię SQLite i snapshot sprzed zmiany nazwy.
