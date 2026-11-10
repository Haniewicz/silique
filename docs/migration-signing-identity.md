# Migracja tożsamości podpisu macOS (CN=Nova Notes Local Preview → CN=Silique)

Data decyzji właściciela: 2026-11-10 (zaktualizowana). Brak konta Apple Developer,
dlatego pozostajemy przy **self-signed**, ale nazwa CN podpisu macOS zmienia się
na `Silique`. Android pozostaje **bez zmian** (ten sam keystore, `CN=Nova Notes`,
alias `nova-notes`). Tożsamości są teraz asymetryczne: macOS `Silique`,
Android `Nova Notes` — świadoma decyzja, nie przeoczenie.

## Co się NIE zmienia

| Identyfikator | Stan |
| --- | --- |
| Keystore i pin Androida (`CN=Nova Notes`, alias `nova-notes`) | bez zmian |
| SHA-256 certyfikatu Androida `2021902e…996e` | bez zmian |
| `SUPublicEDKey` (Ed25519 aktualizatora Sparkle) | bez zmian |
| Bundle id `pl.novanotes.novaNotes` / `pl.novanotes.nova_notes` | bez zmian |
| Katalog danych `Nova Notes` i `/.well-known/nova-notes` | bez zmian |
| Sekrety `ANDROID_*` (keystore BASE64, store/key password) | bez zmian |

## Stary i nowy odcisk macOS

- **Stary** certyfikat `CN=Nova Notes Local Preview`: SHA-256 liścia
  `842a631b45769ded85da4db28638a7060d18628f04b8e721da8f0a3195844217`.
- **Nowy** certyfikat `CN=Silique`: SHA-256 liścia generuje
  `tool/make_signing_identity.sh` (wypisuje go na końcu, wraz z SHA-1 do
  designated requirement). Dopóki właściciel nie wpisze realnego odcisku, pin
  w `tool/macos_dmg.py` jest placeholderem `0000…0000`.

## Wygenerowanie nowej tożsamości (właściciel, macOS)

```sh
export SILIQUE_MACOS_P12_PASSWORD='…'  # hasło PKCS#12; nigdy nie trafia do repo
tool/make_signing_identity.sh "$HOME/.local/share/silique-signing"
```

Wynik: `silique-publisher.p12` + `silique-publisher.crt` oraz wypisany SHA-256
i SHA-1. Po wygenerowaniu **podmień** odcisk w tych trzech miejscach (inaczej
nowy DMG odrzuci własną weryfikację, a testy będą zielone i bezużyteczne):

1. `tool/macos_dmg.py` → `PUBLISHER_CERTIFICATE_SHA256`.
2. `tool/test_macos_dmg.py` → `test_root_metadata_and_native_code_checks_are_exact`
   (mock `Authority=` i pin).
3. `tool/test_branding_compatibility.py` → pin `'tool/macos_dmg.py'`.

SHA-1 z generatora podmień także we wpisie designated requirement
(`certificate leaf = H"{sha1}"`) w `tool/sign_macos.py`, jeśli nie jest on
wyprowadzany automatycznie z pliku `.crt`.

## Jednorazowa ręczna instalacja (tylko macOS)

Rotacja klucza podpisu zmienia `cdhash`/designated requirement, więc
`codesign --verify --deep --strict` starej i nowej paczki nie będą tożsame.
Właściciel akceptuje **jednorazową ręczną reinstalację wyłącznie na macOS**
— Android nie wymaga żadnej akcji użytkowników.

1. Zamknij Silique.
2. Pobierz nowy `Silique-WERSJA-macOS.dmg`, otwórz i przeciągnij `Silique.app`
   do `Applications` z opcją **Replace**.
3. Uruchom jedną kopię z `/Applications` (nie z obrazu DMG), następnie wysuń obraz.
4. Notatki, preferencje i poświadczenia (sandbox, pęk kluczy, identyfikatory)
   pozostają zachowane — podmiana bundle nie wymazuje danych użytkownika.

## Prawda o Gatekeeperze

Notaryzacja self-signed jest **niemożliwa**, więc Gatekeeper nadal blokuje pierwsze
uruchomienie nowej paczki. Remedium dla użytkownika:

- klik prawym przyciskiem → **Otwórz**, albo
- `xattr -d com.apple.quarantine /Applications/Silique.app`.

Nie wyłączać globalnie ochrony systemu i nie usuwać kwarantanny automatycznie
przy instalacji.

## Procedura testu Sparkle (stara → nowa wersja)

Przed publikacją należy sprawdzić, że aktualizator przyjmuje nową tożsamość:

1. Na maszynie testowej macOS zainstaluj **starą** wersję (podpisaną
   `CN=Nova Notes Local Preview`) i potwierdź jej stan/notatki.
2. Wystaw kandydata nowej wersji na kanale **testowym** appcast (nie produkcyjnym).
3. W aplikacji przejdź do Ustawienia → Aktualizacje i wyzwól sprawdzenie.
4. Zaakceptuj pobranie/instalację i potwierdź, że wersja rośnie, a dane/zakładki
   pozostają nienaruszone.

**Jeśli Sparkle odrzuci aktualizację** (np. z powodu zmiany tożsamości podpisu
lub niezgodności designated requirement), należy to odnotować wprost w notatce
wydania i w tym dokumencie — nie należy sugerować, że automatyczna aktualizacja
przechodzi, dopóki nie zostanie zweryfikowana. W takim wypadku jedynym przejściem
dla starszych instalacji macOS pozostaje ręczna reinstalacja DMG z sekcji wyżej.
