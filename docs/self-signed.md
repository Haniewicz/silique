# Certyfikat serwera: self-signed i pinning klucza (SPKI)

## Co widzi użytkownik

Zazwyczaj serwer Silique używany jest przez HTTPS z certyfikatem podpisanym
przez publicznie zaufany urząd certyfikacji (CA). Gdy serwer używa certyfikatu
self-signed (albo jego łańcucha nie uznaje system), przy pierwszym połączeniu
Silique pokazuje dialog „Nieznany certyfikat serwera" z:

- **odciskiem klucza (SPKI)** — SHA-256 klucza publicznego, w grupach po 4 znaki,
  w tym samym formacie, który wypisuje `./infra/install.sh status` (hex, wielkimi literami,
  pole `cert-spki`) — czyli porównujesz znak po znaku, bez konwersji,
- **podmiotem** (`subject`) i **datą ważności** (`notAfter`),
- instrukcją porównania odcisku z tym, który podaje serwer.

Użytkownik powinien zweryfikować odcisk poza aplikacją (np. przez `openssl x509
-noout -fingerprint -sha256 -in /etc/nginx/silique/cert.pem` na serwerze albo
`./infra/install.sh status`). Dopiero wtedy wybiera **„Zaufaj temu serwerowi"**.
Wybór **„Anuluj"** niczego nie zapisuje i połączenie nie zostaje nawiązane.

## Dlaczego pinning klucza jest bezpieczniejszy niż wyłączenie weryfikacji

Wyłączenie weryfikacji TLS (`badCertificateCallback => true`) przyjmuje
**dowolny** certyfikat, zawsze i po cichu — wtedy ktoś, kto podszywa się pod
serwer, może czytać i modyfikować synchronizowane dane bez wiedzy użytkownika.

Pin SPKI jest czymś innym:

- zatwierdzenie dotyczy **jednego konkretnego klucza publicznego** (a nie
  certyfikatu), więc rutynowe odnowienie certyfikatu tym samym `key.pem` nie
  wymaga ponownego potwierdzania,
- odcisk to jawny skrót klucza publicznego, a nie sekret — może leżeć poza
  zaszyfrowanym vaultem i być odczytany przed jego odblokowaniem,
- nie ma ścieżki „ufaj mimo zmiany": gdy klucz się zmieni, Silique **blokuje**
  połączenie i pokazuje odciski oczekiwany/otrzymany,
- wygasły certyfikat nigdy nie zostanie dopuszczony samym pinem.

## Gdy klucz się zmienił (rotacja)

Jeśli klucz został zmieniony celowo (np. wygenerowano nowy `key.pem`), Silique
pokaże dialog „Certyfikat serwera się zmienił" bez przycisku zaufania. Aby
połączyć się ponownie:

1. Zweryfikuj nowy odcisk na serwerze.
2. W **Ustawienia → Zaufany certyfikat serwera** wybierz **„Zapomnij"**
   (z potwierdzeniem). Usunięcie pinu osłabia ochronę do czasu ponownego
   potwierdzenia — dlatego akcja wymaga jawnego potwierdzenia.
3. Przy najbliższej próbie połączenia Silique ponownie pokaże dialog
   „Nieznany certyfikat serwera" i trzeba będzie zatwierdzić nowy odcisk.

## Wygasły certyfikat

Gdy certyfikat wygasł, ale klucz pozostał ten sam, Silique pokazuje dialog
„Certyfikat serwera wygasł". Remedium jest po stronie serwera:

```sh
./infra/install.sh renew-cert
```

Ponieważ polecenie zachowuje dotychczasowy klucz (`key.pem`), SPKI się nie
zmienia i **nie** jest wymagane ponowne potwierdzanie odcisku.
