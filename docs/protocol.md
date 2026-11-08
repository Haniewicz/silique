# Silique Protocol v1

Discovery: `GET /.well-known/silique`. Klient wymaga `api_version=1`, `e2ee=true`, `revision_dag=true`.

## Konta

`POST /v1/auth/register`, `POST /v1/auth/login`: email, password (min. 12 znaków), deviceId UUID, deviceName; przy rejestracji opcjonalne invite. Losowy token 256-bitowy, na serwerze wyłącznie SHA-256, ważny 30 dni, związany z urządzeniem. `POST /v1/auth/logout` unieważnia sesję.

`GET /v1/account` zwraca accountEnvelope. `PUT /v1/account/envelope` przyjmuje nieprzezroczyste envelope i expected (null przy inicjalizacji). Atomowy compare-and-swap chroni klucze przed nadpisaniem przez równoległą inicjalizację.

`GET /v1/devices`; `DELETE /v1/devices/:id` cofa dostęp i usuwa sesje. Logowanie z unieważnionym ID jest odrzucane.

## Vaulty i rewizje

`GET /v1/vaults`; `PUT /v1/vaults/:id`: keyWrap, metadata, expectedVersion (0 dla nowego vaulta). Odpowiedź zawiera kolejną wersję. Wszystkie operacje sprawdzają właściciela konta.

`POST /v1/vaults/:id/batches`:

```json
{"batchId":"UUID","revisions":[{"id":"UUID","noteId":"opaque-id","parents":[],"payload":"opaque AEAD envelope"}]}
```

Do 100 rewizji, żądanie do 4 MB, payload do 2 mln znaków. Rodzice muszą należeć do tej samej notatki i vaulta. Serwer w jednej transakcji zapisuje rewizje, aktualizuje głowy DAG i utrwala potwierdzenie batcha. Równoległe gałęzie są zachowywane, brak last-write-wins. Ten sam batchId i identyczne żądanie zwracają to samo potwierdzenie; inny payload zwraca 409. Rodzice mogą być dodani wcześniej w tym samym batchu.

`GET /v1/vaults/:id/changes?cursor=0&limit=100` zwraca revisions, monotoniczny cursor, hasMore. Kursor osobny dla każdego vaulta. Pobierz wszystkie strony przed scalaniem. Usunięcie, tytuł, folder, tagi i dziennik są zaszyfrowane wewnątrz payloadu. ID dziennika: HMAC-SHA256(VaultKey, `journal:YYYY-MM-DD`).

Klient utrwala dokładny zaszyfrowany batch przed transmisją. Usuwa go po weryfikacji kompletnego potwierdzenia. Utrata odpowiedzi wymaga ponowienia tego samego batcha także po restarcie. Wspólny przodek umożliwia three-way merge; sprzeczne wersje otrzymują deterministyczne kopie konfliktowe. Historia pozostaje niezmienna.

## Parowanie X25519

`POST /v1/pairings`: publicKey (32 B Base64) zalogowanego nowego urządzenia. `GET /v1/pairings`: żądania tylko tego konta, ważne 10 minut. Drugie urządzenie przesyła publicKey do `POST /v1/pairings/:id/offer` (CAS, inne urządzenie). X25519 + HKDF-SHA256 używa kontekstu wiążącego konto, pairingId, oba deviceId i oba klucze publiczne. Użytkownik porównuje pełny 16-znakowy kod na obu urządzeniach. Dopiero po potwierdzeniu starsze urządzenie wysyła AES-GCM kopertę Account Master Key do `POST /v1/pairings/:id/approve`. Klient weryfikuje kontekst i własny klucz publiczny. Serwer nie otrzymuje prywatnych kluczy ani jawnego klucza konta.

## Przyszły Web

Domena i kryptografia nie importują dart:io. NoteStorage, KeyStore, CryptoProvider, SyncTransport, UpdateProvider są granicami adapterów. API jest wersjonowane, CORS jawny. Web będzie wymagał HTTPS, przeglądarkowego magazynu kluczy, CSP i polityki dostarczania kodu, cookies/CSRF. Aktualnie brak webowego UI i uwierzytelniania cookies.
