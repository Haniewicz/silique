# Aktualizacje Silique z publicznego repozytorium instalatorów

Od 0.2.30 nowe paczki macOS są wyłącznie DMG, używane także przez Sparkle.
Manifest stosuje `macos-dmg`; nowy klient mapuje ten wpis na platformę macOS,
a stary Android/Linux bezpiecznie go ignoruje. Stary Mac (do 0.2.29 włącznie)
wymaga jednorazowej ręcznej instalacji DMG. Nie publikować nowego ZIP macOS.
[Kontrakt i granica zgodności](DMG_DISTRIBUTION.md); [wyniki wydania](0.2.30.md).
Poniższe starsze opisy wydań zachowano jako historię.

Dystrybucja: https://github.com/Haniewicz/silique-releases. Publicznie są tylko instalatory, README oraz podpisane kanały latest.json i appcast.xml. Kod aplikacji i serwera pozostaje w prywatnych repozytoriach. Pierwsza opublikowana wersja z updaterem to 0.2.5+10 (2026-10-21); przejście ze starszych wersji wymaga ręcznej instalacji. Opublikowane wcześniej 0.2.4+8 nie zawiera updatera. Aktualny kanał wskazuje zatwierdzone 0.2.8+17; po publikacji sprawdzono podpis kanału i pobranie APK przez rzeczywistego klienta bez konta GitHub.

## Zachowanie aplikacji

Po uruchomieniu (po 8 sekundach) i co 6 godzin aplikacja sprawdza podpisane informacje o najnowszym wydaniu. W ustawieniach jest ręczne sprawdzanie oraz bieżący numer wersji odczytany z systemu. Dostępna aktualizacja wyświetla powiadomienie i opis zmian. Pobieranie i instalacja wymagają działania użytkownika. Brak sieci nie blokuje notatek; automatyczne nieudane sprawdzenie pozostaje ciche.

macOS korzysta ze Sparkle 2.10.0, z podpisanym kanałem i podpisem Ed25519 archiwum weryfikowanym przed rozpakowaniem. Sandbox pozostaje włączony, a Installer.xpc obsługuje instalację poza sandboxem. Przed ponownym uruchomieniem Flutter potwierdza zapis edytora; błąd zapisu wstrzymuje instalację. Zapis kończy również zmiany dopisane podczas trwającego zapisu; test odtwarza ten wyścig. Lokalne podpisy Apple oraz brak notaryzacji pozostają takie jak w poprzednich paczkach — pełny restart po aktualizacji wymaga ręcznego testu podpisanej wersji.

Android pobiera APK strumieniowo do własnego cache. Sprawdza liczbę bajtów i SHA256, a dopiero po zakończeniu zmienia nazwę pliku tymczasowego. Można anulować pobieranie. Native installer ponownie sprawdza aplikację, nowszy versionCode i ten sam certyfikat. FileProvider udostępnia instalatorowi tylko katalog cache z aktualizacjami. W razie potrzeby system prosi o zezwolenie na instalowanie z Silique; po powrocie zweryfikowany plik jest używany ponownie. Instalację potwierdza użytkownik w oknie Androida.

## Autentyczność i prywatność

Aplikacja ma stały adres kanału producenta; aktualizacje nie pochodzą z dowolnego serwera synchronizacji wskazanego przez użytkownika. Metadane są podpisane Ed25519 i wiążą wersję, build, docelowe adresy GitHub, rozmiary i SHA256. Podpis jest sprawdzany przed wykorzystaniem informacji. Starszy lub ten sam build nie jest oferowany do instalacji. W aplikacji są wyłącznie klucze publiczne, bez tokenów GitHuba.

Klucz prywatny aktualizacji jest przechowywany oddzielnie od repozytoriów: konto Keychain `pl.silique.updates`, kopia właściciela `~/.local/share/silique-signing/updater-ed25519.key` (0600). Zachowaj bezpieczną kopię razem z dotychczasowymi materiałami podpisu Android/macOS. Nie zapisuj jego zawartości w repozytorium ani w zgłoszeniach. Rotacja klucza wymaga osobno przygotowanej migracji; sam nowy klucz na serwerze nie wystarczy starym klientom.

## Publikowanie zatwierdzonego wydania

macOS i Android budujemy i podpisujemy lokalnie. Od 2026-10-21 właściciel zezwolił na bezpłatny standardowy runner GitHub Actions do budowania Windows w publicznym repo instalatorów. Źródła pobierane są z prywatnego repo przez osobny klucz tylko do odczytu. Log kompilacji trafia do artefaktów wyłącznie po zaszyfrowaniu kluczem publicznym właściciela. Publikacja wydania nadal wymaga osobistego testu i potwierdzenia właściciela. Szczegóły Windows oraz eksperymentalnego Linux GTK4: [wydania desktopowe](desktop-packages.md).

W 0.2.6 updater instalujący z aplikacji obejmował macOS i Android. Opublikowane 0.2.7 dodaje Linux RPM/DEB: format wykrywany jest przez właściciela rzeczywistego pliku wykonywalnego (`silique` w RPM/dpkg), nie przez samą obecność menedżera pakietów. Sprawdzanie jest automatyczne, a pobranie i instalacja następują dopiero po kliknięciu użytkownika. Przed instalacją sprawdzane są podpis Ed25519 manifestu, kanoniczny URL, rozmiar i SHA256 paczki, następnie zapisywane są notatki. `pkexec` uruchamia systemowy `dnf upgrade` albo `apt-get install`; autoryzacja odbywa się w oknie systemu. Nie wyłączamy kontroli podpisów RPM. Katalog pobierania jest losowy, tworzony atomowo i na Linuxie wymaga zweryfikowanych uprawnień 0700. Przenośne archiwum tar i Windows pozostają ręczne. Po udanej instalacji Linux wymaga zamknięcia i ponownego uruchomienia aplikacji. Przejście z Linux 0.2.6 do 0.2.7 jest ręczne. Kanał 0.2.7+12 opublikowano 2026-10-22 z właściwym dotychczasowym kluczem Ed25519.

1. Zbuduj wersję z rosnącym numerem build; oba instalatory muszą mieć tę samą wersję i build. Uruchom analizę, testy, zweryfikuj podpisy. `tool/sign_macos.py` podpisuje również helpery Sparkle od wewnątrz na zewnątrz.
2. Napisz publiczny opis zmian, bez lokalnych ścieżek, danych kont, adresów infrastruktury ani raportów wewnętrznych.
3. Przygotuj pliki:

```sh
python3 tool/prepare_update.py --version WERSJA --build BUILD \
  --macos /sciezka/Silique-macOS.dmg --android /sciezka/Silique.apk \
  --notes /sciezka/publiczne-zmiany.txt --out /sciezka/nowy-katalog-wydania
```

W wydaniu wieloplatformowym dodaj `--windows`, `--windows-portable`, `--linux`, `--linux-deb` i `--linux-rpm`. Windows wymaga pary EXE/ZIP, Linux kompletu archiwum/DEB/RPM. Podpisany manifest oraz sumy kontrolne obejmują wszystkie dostarczone paczki; starsze klienty macOS/Android zachowują zgodność kanału.

4. Po osobistym teście i potwierdzeniu właściciela opublikuj:

```sh
python3 tool/publish_update.py --prepared /sciezka/nowy-katalog-wydania \
  --repository '../Silique Releases' --publish
```

Narzędzie odrzuca obcy repozytorium, nieoczekiwane pliki i cofnięcie numeru build. Najpierw przesyła draft, porównuje SHA256 po stronie GitHuba, publikuje instalatory, a następnie aktualizuje oba podpisane kanały w publicznym repo. Nie kopiuje historii ani źródeł aplikacji. Nie zmieniaj podpisanych kanałów ręcznie — zmiana treści wymaga ponownego podpisania.

Oficjalne narzędzia Sparkle są w `~/.local/share/silique-toolchains/sparkle-2.10.0/`; wersja frameworka jest zablokowana w Swift Package Managerze. Publiczny klucz w kodzie aplikacji i Info.plist musi odpowiadać kluczowi użytemu do podpisania wydań.
