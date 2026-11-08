# Dystrybucja macOS jako DMG (od 0.2.30)

## Stała decyzja właściciela

Nowe publiczne wydania macOS zawierają wyłącznie
`Silique-WERSJA-macOS.dmg`, bez równoległej paczki macOS ZIP. Windows ZIP
pozostaje bez zmian. Historycznych wydań macOS ZIP nie usuwamy.
Ten sam obraz DMG obsługuje pierwszą instalację i aktualizator Sparkle.

Obraz zawiera jedną aplikację `Silique.app` oraz skrót `/Applications`.
Instalacja ręczna: zamknąć Silique, otworzyć DMG, przeciągnąć aplikację do
Applications/Programy i zastąpić dotychczasowy bundle, wysunąć obraz, uruchomić
jedną kopię z `/Applications`. Bez kasowania notatników, ustawień i poświadczeń.

## Manifest i zgodność

Stary `AppRelease.verify` waliduje wszystkie rozpoznawane platformy, nie tylko
bieżący system. Podmiana URL pod dotychczasowym kluczem `macos` z `.zip` na
`.dmg` zerwałaby więc również aktualizacje Android/Linux.

Nowy manifest schematu 1 emituje klucz **`macos-dmg`** z kanoniczną nazwą
`Silique-WERSJA-macOS.dmg`. Nie emituje pola `macos`. Dotychczasowe aplikacje
ignorują nieznany klucz i nadal przyjmują swoje APK/DEB/RPM. Nowy klient
waliduje dokładny URL DMG i mapuje go na wewnętrzną platformę `macos`.
Dla odczytu historycznych kanałów zachowuje obsługę pola `macos`/ZIP; nie wolno
osłabiać walidacji URL, podpisów, rozmiarów ani sum. Dwa równoczesne wpisy dla
macOS są niejednoznaczne i muszą być odrzucone.

**Granica migracji: macOS 0.2.29 i starszy wymaga jednorazowej ręcznej instalacji
nowego DMG.** Jego interfejs aktualizacji wymaga starego pola `macos`, a Sparkle
nie uruchamia się samodzielnie w tle. Nie można zdalnie zmienić już wydanego
parsera bez zgodnej paczki ZIP, której właściciel nie chce od nowych wydań.
Nie należy twierdzić, że starszy Mac automatycznie dokona tej migracji.

## Zachowanie zabezpieczeń

- Zachować bundle ID, oznaczenia sandboxa, dotychczasowy certyfikat aplikacji,
  klucze Keychain i publiczny klucz Ed25519 aktualizatora.
- Podpis Sparkle dotyczy ostatecznych bajtów DMG. Appcast wskazuje dokładnie
  opublikowany obraz z poprawną długością, podpisem, wersją i numerem build.
- Przed publikacją sprawdzić obraz natywnym `hdiutil`, zamontować tylko do odczytu,
  zweryfikować root bundle i jego podpis, a następnie odmontować także po błędzie.
- DMG nie zapewnia Developer ID ani notaryzacji. Brak tych elementów oznacza,
  że Gatekeeper nadal może wymagać indywidualnego „Otwórz mimo to”. Nie usuwać
  kwarantanny automatycznie i nie wyłączać globalnie ochrony systemu.

Wyniki rzeczywistego wykonania, SHA i runy wydania zapisuje `docs/0.2.30.md`.
