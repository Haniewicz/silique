# Silique na koncie Hermesa

Konfiguracja 2026-10-22. AiBrain / CT 103, konto `hermes` (UID 1000), katalog
`$HOME/projects/Silique`. Prywatne repozytoria `Silique App` i
`Silique Server`, osobne publiczne `Silique Releases`. Zachowano historię
Git, także lokalny commit serwera 0.2.3, który jeszcze nie był na origin.
Kopie nie zawierają vaultów ani pliku z zaproszeniem właściciela.

## Narzędzia i dostęp

- `silique` jest w `~/.local/bin`; źródło narzędzia: `tool/hermes/silique`.
  Root-owned wrappery w `/usr/local/bin` udostępniają `silique`, `flutter` i
  `dart` także w nieinteraktywnym SSH i narzędziach agenta; przyjmują
  wyłącznie UID Hermesa i nie podnoszą uprawnień.
- Node 24.22.0 / npm, GitHub CLI, Git, Python, rsync oraz Flutter 3.47.7.
  Flutter: `~/.local/share/silique-toolchains/flutter/bin/flutter`.
- GitHub CLI zalogowano jako właściciel `Haniewicz` przez jednorazowy kod
  urządzenia zatwierdzony przez właściciela. Dane logowania są poza projektem,
  w `~/.config/gh/hosts.yml`, 0600. To autoryzacja OAuth GitHub CLI, a nie
  token ograniczony do trzech repozytoriów. Nie wypisywać tego pliku ani tokenu.
  Wycofanie: `gh auth logout --hostname github.com`, a następnie odebranie
  autoryzacji GitHub CLI w ustawieniach konta GitHub.
- Materiały podpisu macOS/Android/updatera są w GitHub Actions Secrets
  repozytorium instalatorów; używane są dotychczasowe klucze. Klucz do
  odszyfrowania prywatnych raportów jest u Hermesa w
  `~/.local/share/silique-signing/desktop-diagnostics.key.pem`, 0600.
- Sprawdzenie: `silique doctor`. Nie publikuje, nie wdraża i nie uruchamia CT 104.

## Deploy serwera

1. W `Silique Server` pobierz aktualny kod i sprawdź wybrany SHA.
2. `silique server-package SHA` tworzy osobny build z archiwum Git, uruchamia
   kontrolę typów, 14 testów i kompilację, usuwa zależności developerskie,
   pakuje kod i przesyła do `~/silique-incoming` na CT 100. Na koniec wykonuje
   kontrolę paczki przez docelowy mechanizm. Nie przełącza działającej usługi.
3. `silique deploy ID` przełącza wyłącznie usługę Silique w CT 100.
4. `silique rollback ID-ISTNIEJĄCEGO-WYDANIA` wraca do zachowanego kodu.

CT 100: alias `silique-deploy`, użytkownik `hermes`, jedyne sudo:
`sudo -n /usr/local/sbin/silique-deploy status|check|deploy|rollback ...`.
Wrapper, backup helper i sudoers są własnością roota. Archiwum nie może
zawierać linków, plików urządzeń, obcych katalogów ani ścieżek poza wydaniem.
Kod paczki nigdy nie jest wykonywany jako root. Wydania są root-owned,
proces nadal działa jako `silique`. Hermes nie ma ogólnego sudo.

Przed przełączeniem powstaje backup online oraz druga spójna kopia przy
zatrzymanej usłudze z `quick_check=ok`, w `/var/backups/silique/deploy-*`.
Przełączenie jest atomowe; błędny start/health przywraca poprzedni kod.
Automatycznie nie odtwarza się bazy: migracje powinny być addytywne i
zgodne z poprzednim wydaniem. Ryzykowna zmiana schematu wymaga osobnego planu.
Historia wdrożeń: `/var/lib/silique-deploy/history.jsonl` i journald.
Po wdrożeniu sprawdź discovery, dziennik oraz właściwe testy funkcjonalne.

## Budowanie aplikacji

Od 0.2.30 paczka macOS kandydata to `Silique-macOS.dmg`, a publiczna
`Silique-WERSJA-macOS.dmg`. `tool/macos_dmg.py` oraz proces CI budują i
weryfikują obraz; collect, przygotowanie i publikacja przyjmują DMG, nie ZIP.
Manifest emituje `macos-dmg`. [Kontrakt zgodności](DMG_DISTRIBUTION.md).

`silique build-candidates SHA` uruchamia wyłącznie ręczne workflow:
`macos-android.yml` oraz `windows.yml` w publicznym repo instalatorów.
Podaj pełny SHA już obecny na `origin/main` prywatnej aplikacji. Kod pobiera
istniejący klucz tylko do odczytu; kompilator i testy zapisują wyłącznie
zaszyfrowaną diagnostykę. Artefakty zawierają paczki, sumy i raporty,
bez źródeł, tokenów ani kluczy. Standardowe runnery, bez płatnych rozmiarów,
bez automatycznych wyzwalaczy push/PR. macOS nie wymaga dostępu do Maca
właściciela ani instalowania tam aplikacji.

`silique linux-build SHA` korzysta z istniejącego CT 104 / Ubuntu 24.04,
użytkownika `builder` i zachowanego SDK GTK4, rootfs Fedory i PRoot.
Dedykowany klucz do Proxmoxa pozwala wyłącznie na `status`, `start`,
`shutdown`, `address` kontenera 104. Nie daje powłoki roota ani `pct exec`.
SSH do kompilacji działa jako `builder`. Klucze hostów są przypięte.
Adres jest odczytywany po starcie, więc nie zależy od poprzedniego DHCP.
Jeśli narzędzie uruchomiło zatrzymany CT, wyłączy go po zakończeniu lub błędzie.
`onboot: 0` i cache zostają zachowane. Różna łatka silnika zatrzymuje build;
najpierw należy zaktualizować i przebudować osobny SDK, nie pomijać kontroli.
Wyniki są pobierane do `artifacts/linux-*` z SHA źródła. Równoległe budowanie
chroni blokada na builderze. Natywne próby instalacji DEB/RPM i osobisty test
właściciela nadal są częścią oceny nowego wydania.

Postęp: `gh run list -R Haniewicz/silique-releases` / `gh run watch ID ...`.
Zaszyfrowane logi można pobrać przez `gh run download`, a następnie odszyfrować:

```sh
openssl cms -decrypt -binary -inform DER -in private-build.cms \
  -recip ~/.local/share/silique-signing/desktop-diagnostics.cert.pem \
  -inkey ~/.local/share/silique-signing/desktop-diagnostics.key.pem \
  -out private-build.log
```

Zachowaj odszyfrowane raporty prywatnie. Artefakty kandydatów/diagnostyki
wygasają po jednym dniu: pobierz je od razu.

## Przygotowanie i publikacja wydania

Po sprawdzeniu zgodności SHA źródła, wersji/build oraz wszystkich paczek:

```sh
silique collect SHA --macos-run ID --windows-run ID \
  --linux-dir $HOME/projects/Silique/artifacts/linux-... \
  --notes /sciezka/do/publicznych-zmian.txt
```

Polecenie pobiera macOS/Android/Windows, dodaje lokalny Linux i przesyła
wyłącznie siedem instalatorów do nieopublikowanego szkicu
`candidate-WERSJA-BUILD`. Następnie uruchamia ręczny `update-release.yml`
w trybie `prepare`: podpisanie obu kanałów dotychczasowym kluczem na macOS,
weryfikacja wersji/Android certyfikatu i utworzenie artefaktu
`silique-prepared-update` (7 dni). Kanały publiczne pozostają bez zmian.
Pełna diagnostyka pozostaje zaszyfrowana.

**Dopiero po osobistym teście i wyraźnym potwierdzeniu właściciela:**

```sh
silique publish SHA --prepared-run ID-UDANEGO-PRZYGOTOWANIA --owner-approved
```

Ręczny workflow uruchamia istniejący, weryfikujący `publish_update.py` na
macOS. Najpierw przesyła i sprawdza publiczne zasoby, później aktualizuje
podpisane kanały. Samo przygotowanie konta ani wcześniejsza zgoda dotycząca
innego wydania nie są zgodą na publikację kolejnej wersji. Nie uruchamiaj
historycznego workflow `build.yml` z prywatnego repo — oficjalne paczki
wykorzystują opisane osobne workflow i GTK4, bez automatycznych wyzwalaczy.
