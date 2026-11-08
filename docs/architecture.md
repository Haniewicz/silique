# Architektura

`lib/core`: modele domeny, kontrakty, AES-GCM/Argon2id/X25519/HKDF, three-way merge. Bez dart:io i zależności od ekranu.

`lib/services`: repozytorium notatek i silnik synchronizacji; HTTP transport. `lib/storage`: natywne adaptery SQLite, pliki, systemowy magazyn kluczy, haszowanie w izolacie oraz obsługa okna. `lib/ui`: interfejs i ekran ustawień. Riverpod dostarcza repozytorium. Protokół v1 jest udokumentowany w obu repozytoriach.

Wybrano niewielki jawny adapter sqlite3 zamiast generowanych modeli Drift. Granica NoteStorage pozwala dodać adapter Drift lub IndexedDB/OPFS bez zmiany domeny. Wyszukiwanie działa lokalnie na odblokowanych dokumentach; chroniony tekst nie jest zapisywany w jawnym indeksie. Zewnętrzne zmiany kopii .md nie są automatycznie obserwowane; import i eksport są jawne.

## Klucze

Losowy klucz instalacji oraz klucze konta są w Keychain/Android Keystore/Windows secure storage/Secret Service. Standardowe klucze vaultów mają lokalną kopertę pod kluczem instalacji i zdalną kopertę pod kluczem konta. Dodatkowo chronione vaulty mają wyłącznie kopertę Argon2id oraz niezależną kopertę odzyskiwania. Hasło konta nie odszyfrowuje notatek.

Klucze vaultów mają 32 losowe bajty, AES-256-GCM z losowym nonce i AAD wiążącym kontekst. Argon2id: 64 MiB, 3 iteracje, parallelism 1, losowa sól 16 B. Hasło vaulta nigdy nie trafia do serwera. Zmiana hasła przepakowuje klucz, zachowuje kopertę odzyskiwania i używa zdalnego CAS.

Parowanie: X25519 + HKDF-SHA256, osobna tożsamość instalacji dla serwera i konta. Oba klucze publiczne i identyfikatory są związane kontekstem. Zaufane urządzenie przekazuje Account Master Key dopiero po ręcznej weryfikacji całego kodu na obu ekranach. Konto odzyskuje się również osobnym losowym kluczem odzyskiwania, którego serwer nie otrzymuje.

Chronione notatki, ich nazwy, foldery, tagi i metadane są zaszyfrowane lokalnie; wyszukiwanie działa w RAM. Standardowe notatki mają jawne kopie .md, co wymaga systemowego szyfrowania dysku. Blokada chronionego vaulta usuwa dane z aktywnego edytora i jego historii undo; Dart nie gwarantuje wyzerowania wszystkich kopii pamięci. Eksport tworzy jawną kopię na wyraźne żądanie.

## Synchronizacja

Lokalny dokument i rewizja trafiają do jednej transakcji SQLite. Każdy dokument pamięta rewizje faktycznie obejrzane przez użytkownika, więc pobranie nieznanej gałęzi podczas pisania nie oznacza jej niejawnego zaakceptowania. Zaszyfrowany batch jest utrwalany przed wysłaniem, ponawiany dokładnie po utracie potwierdzenia i usuwany dopiero po weryfikacji ACK.

Serwer zachowuje DAG i wszystkie równoległe wersje. Klient pobiera wszystkie strony, weryfikuje AEAD, oblicza wspólnego przodka i scala niekolidujące fragmenty. Konfliktujące wersje otrzymują deterministyczne kopie. Edycja jest zachowana przy konflikcie z usunięciem. Historia nie jest usuwana. Duże dokumenty poza limitem bezpiecznego scalania stają się kopiami konfliktowymi zamiast ryzykować utratę.

Serwer nadal widzi rozmiary, identyfikatory, czas i powiązania rewizji oraz może ukrywać/usuwać dane. Brak audytu produkcyjnego, dziennika transparentności i pełnej rotacji historii po kompromitacji klucza.

## Web w przyszłości

Wersjonowany protokół, interfejsy CryptoProvider/KeyStore/NoteStorage/SyncTransport/UpdateProvider i czysta domena pozostają wspólne. Konieczne będą adaptery przeglądarkowe, HTTPS, CSP, bezpieczny magazyn kluczy oraz osobny projekt cookies/CSRF i zaufanego dostarczania kodu. Nie utworzono PWA ani webowego UI.

HTTP jest dopuszczone wyłącznie dla loopback i adresów Tailscale (100.64.0.0/10, .ts.net). W testowym homelabie warstwę transportową szyfruje Tailscale/WireGuard; aplikacja nadal stosuje E2EE. Dowolny publiczny lub zwykły LAN HTTP jest odrzucany.
