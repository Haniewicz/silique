# Silique — zmiana nazwy 0.2.0

Repozytoria: Haniewicz/silique-app i Haniewicz/silique-server. Zmieniono nazwę aplikacji, kodu Dart, interfejsu, plików wykonywalnych, paczek i dokumentacji. Android zachowuje applicationId `pl.novanotes.nova_notes`, macOS bundle ID `pl.novanotes.novaNotes`; dzięki temu aktualizacja zachowuje sandbox, notatki i klucze. Klucz podpisu Androida i certyfikat lokalnego podpisu macOS pozostały te same. Ich starsze nazwy w certyfikatach i aliasach są identyfikatorami zgodności.

Domeny AEAD/HKDF `nova:1:…`, istniejące sloty kluczy `nova.*`, macOS service `pl.novanotes.keys` oraz GTK ID pozostają trwałymi identyfikatorami protokołu v1. Ich zmiana unieważniłaby dostęp do dotychczas zaszyfrowanych notatek. Nie są marką interfejsu. Poniższy jawny kontrakt obejmuje również instalację, migrację, podpis i historyczną proweniencję — nie obiecujemy usunięcia identyfikatorów kosztem danych.

## Wąskie wyjątki zgodności

- Katalog poprzedniej instalacji rozpoznaje wyłącznie resolver migracji i jego rzeczywiste testy. Nazwy `nova.sqlite`, `nova.sqlite-wal`, `nova.sqlite-shm` pozostają wejściami bezpiecznej migracji/recovery; nie tworzą drugiego magazynu.
- Android application ID i GTK ID oraz macOS bundle ID powyżej, sufiksy `.RunnerTests`, `-spks` i `-spki` zachowują instalację, sandbox i Sparkle.
- Sloty `nova.localKey`, `nova.session`, `nova.deviceName`, `nova.lastVault`, `nova.keys.v1` oraz rodziny `nova.account.` i `nova.identity.` zachowują oryginalne klucze, sesje i tombstones. Nie zmieniamy pełnych domen kryptograficznych ani ich parametrów.
- Windows DPAPI zachowuje bieżącego użytkownika, dotychczasowe parametry/entropy i `flutter_secure_storage.dat`; nie ma resetu ani automatycznego fallbacku.
- Alias podpisu Androida pozostaje bez zmiany. Historyczny certyfikat `Nova Notes Local Preview` zachowuje dokładnie te same bajty i designated requirement; nowa nazwa produktu nie uprawnia do rotacji podpisu.
- Zachowane stare protokoły/discovery oraz wzmianki o dokładnych identyfikatorach w historycznych raportach opisują rzeczywiste wydania, nie aktualną nazwę UI.

`tool/test_branding_compatibility.py` zawiera allowlistę dokładnych literałów i ścieżek, odrzuca dawną markę poza nimi (także nowe logi w dozwolonym pliku) oraz przypina tożsamość danych/podpisu. `test/rebrand_migration_test.dart` sprawdza rzeczywistą migrację zaszyfrowanych notatek, kluczy i oczekujących rewizji. Nie maskujemy wyjątków przez składanie nazw z fragmentów ani ślepy replace.

Przy starcie aplikacja przenosi cały poprzedni katalog danych do Silique. Przed zmianą nazwy pliku SQLite wykonuje checkpoint WAL i zamyka bazę. Jeśli znajdzie dwa katalogi lub dwie bazy, zatrzymuje otwieranie bez nadpisywania. Test migracji potwierdza zachowanie chronionej treści, tożsamości i oczekujących rewizji bez zmiany kluczy.

Nowy discovery: `/.well-known/silique`. Serwer zachowuje starszą ścieżkę `/.well-known/nova-notes` jako alias, a klient stosuje ją tylko po 404 nowej ścieżki. Adres API Tailscale i port nie zmieniają się.

LXC CT 100: silique, użytkownik/grupa silique (ten sam UID/GID), usługi silique.service i silique-backup.timer; kod /opt/silique, Node /opt/silique-node, dane /var/lib/silique/silique.sqlite, konfiguracja /etc/silique/server.env i kopie /var/backups/silique. Przed migracją wykonano backup SQLite i snapshot CT.

2026-10-20: użytkownik potwierdził, że po zatwierdzeniu dostępu do pęku kluczy widzi swoje dotychczasowe notatki w Silique 0.2.0. Potwierdzenie dotyczy rzeczywistej instalacji macOS po zmianie nazwy.

## Migracja kryptograficznych domen zapisu `nova:1` → `silique:2`

Wydanie przełącza **zapisy** danych trwałych na domenę AEAD `silique:2:`
(notatki, `vault-key`, `vault-key:recovery`, `vault-meta`, `folder-base`,
`local-note`, `local-vault`). Odczyt pozostaje kompatybilny w obie strony przez
`openCompat`: klient najpierw próbuje nowej domeny, a po błędzie uwierzytelnienia
czyta starą `nova:1:`. Każda notatka skonwertuje się przy pierwszym zapisie.

| Co | Status |
| --- | --- |
| Zapis notatki / rewizji, `vault-key`, `vault-key:recovery`, `vault-meta`, `folder-base`, `local-note`, `local-vault` | **Migruje** do `silique:2:` (przy pierwszym zapisie) |
| Odczyt starych danych `nova:1:*` | **Zostaje** jako fallback (`openCompat`), bezterminowo do osobnego wydania |
| Slot pęku kluczy `nova.keys.v1` | **Migruje** do `silique.keys.v2` (kopia → potwierdzenie → usunięcie) |
| Wewnętrzne sloty `nova.<x>` (session, deviceName, lastVault, account) | **Migrują** do `silique.<x>`; `nova.localKey` i `nova.identity.*` (nieodtwarzalne) **na końcu** |
| Koperta konta `nova:1:account:*` i AAD parowania `nova:1:pairing` | **Zostają** na zawsze |
| Platformowe identyfikatory zgodności (application/bundle ID, alias i certyfikat podpisu, kanał aktualizacji, wpis Keychain) | **Zostają** (identyfikatory zgodności, nie marka) |
| Namespace `silique:1:` (ukryte notatki, obrazy) | **Zostaje** bez zmian (inna domena) |
| Fallback odczytu `nova:1:*` | **Zostaje**; jego usunięcie to **osobne wydanie** po potwierdzeniu właściciela |

### Następne wydanie (nie teraz)

- Usunięcie fallbacku odczytu `nova:1:*` (po potwierdzeniu właściciela, że
  wszystkie instalacje zakończyły konwersję zapisów).

