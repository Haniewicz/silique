# Przekazanie Silique Hermesowi — 2026-10-22

Projekt jest na AiBrain / CT 103, konto `hermes`, UID 1000:
`$HOME/projects/Silique`. Zachowano historię prywatnych repozytoriów
aplikacji i serwera oraz osobne publiczne repo instalatorów. Nie kopiowano
vaultów, pliku zaproszenia ani konfiguracji działającego API do projektu.
Instrukcja dalszej pracy: [hermes.md](hermes.md).

## Komplet rzeczywistych buildów

Wszystkie poniższe paczki zbudowano z tego samego prywatnego commitu:
`ce1a247cf5234411e26388248664ee2fe628f51a`, Silique 0.2.8+17.
Zmiany wprowadzone podczas konfiguracji dotyczą narzędzi i dokumentacji,
bez zmiany zachowania aplikacji. To próba infrastruktury, a nie nowe wydanie.

| Platforma | Paczki i weryfikacja |
| --- | --- |
| macOS | Uniwersalny ZIP arm64/x86_64; dotychczasowy certyfikat, identyfikator `pl.novanotes.novaNotes`, podpis całej aplikacji i Sparkle zweryfikowany; analiza czysta, 153 testy zaliczone i 16 jawnie pominiętych. |
| Android | Uniwersalny APK, dotychczasowy certyfikat SHA256 `2021902e8c43d5c10059c9f0458ed8c1ac94fce86a488f7b46d0b0eb3467996e`; podpis v2 zweryfikowany. |
| Windows | EXE i ZIP x64; natywny test SQLite/magazynu kluczy/edytora oraz prawdziwa próba instalatora przeszły (`nativeStorageTest=true`, `installerSmoke=true`); rozmiary i SHA256 zgodne z raportem. |
| Linux GTK4 | DEB, RPM i tar.gz; analiza czysta, 158 testów zaliczonych, 11 jawnie pominiętych bez API/publicznego smoke; 14 kontroli natywnego AOT zaliczonych, zależności sprawdzone, trzy SHA256 poprawne. |

macOS/Android: [workflow 39838709399](https://github.com/Haniewicz/silique-releases/actions/runs/39838709399).
Windows: [workflow 39841287306](https://github.com/Haniewicz/silique-releases/actions/runs/39841287306).
Linux: kompilacja jako `builder` w istniejącym CT 104, wywołana jako Hermes.
Pochodzenie źródeł sprawdzono w obu artefaktach GitHub i lokalnym `SOURCE_COMMIT`.

Osobno na CT 103 przeszło 168 testów aplikacji z jednorazowym API,
1 test publicznego kanału pominięto; analiza bez uwag. Testowe API było
tylko na loopback, z osobną bazą w pamięci. Zakończono je po testach.

## Przygotowanie wydania

Rzeczywiste `silique collect` pobrało i sprawdziło pochodzenie paczek,
zebrało siedem instalatorów do szkicu i uruchomiło
[podpisywanie 39843202880](https://github.com/Haniewicz/silique-releases/actions/runs/39843202880).
Workflow zakończył się sukcesem: dotychczasowy klucz Ed25519, oba kanały,
tożsamość/wersja APK i macOS, siedem sum i weryfikacja podpisu przez klienta.
Poprzednia próba na oryginalnych publicznych paczkach:
[39837395405](https://github.com/Haniewicz/silique-releases/actions/runs/39837395405).

Paczki i raporty na AiBrain:

- `artifacts/macos-android-39838709399/` — ZIP, APK i prywatna diagnostyka.
- `artifacts/linux-ce1a247cf523-1792697896/` — komplet Linux i raport AOT.
- `releases/candidate-0.2.8-17/` — pobrane artefakty Windows/macOS/Android i komplet instalatorów.
- `releases/prepared-verification-complete-0.2.8-17/` — podpisana próba przygotowania całego wydania.

To przebudowane paczki testowe tej samej wersji 0.2.8+17. Nie publikować
ich jako zastępstwa istniejącego wydania. Testowy szkic GitHub usunięto;
publiczna wersja i oba kanały pozostały bez zmian. Nowa wersja wymaga
rosnącego build, osobistego testu i potwierdzenia właściciela.

## Deploy i uprawnienia

Serwer: 14 testów, kontrola typów i kompilacja jako Hermes zaliczone.
Prawdziwa paczka przeszła `silique-deploy check` na CT 100.
Helper wykonał spójny backup z `quick_check=ok`; prawa kopii 0600.
Odrzucenie linków w archiwum i limitowanie paczek sprawdzone.
Przełączenie kodu, prawa plików, historię i powrót po błędzie health
przetestowano w izolowanym katalogu, z atrapą sterowania usługą.
Nie wykonywano rzeczywistego przełączenia ani restartu działającego API.
Aktywne pozostaje `/opt/silique/releases/20261022-0.2.3-live-sync`,
proces jako `silique`, health i discovery poprawne, rejestracja invite.

Hermes nie dostał ogólnego sudo ani powłoki roota. Na CT 100 ma wyłącznie
walidowany mechanizm wdrożenia. Dostęp do Proxmoxa z AiBrain jest wymuszony
do `status/start/shutdown/address` wyłącznie CT 104, kluczem SSH, bez haseł,
PTY i tunelowania. Dowolne `id`/`pct exec` i ogólne sudo są odrzucane.
Rzeczywisty cykl start/SSH/shutdown przeszedł; CT 104 ponownie zatrzymany,
`onboot: 0`, cache zachowany. Obie usługi Hermesa działają.

GitHub CLI został zatwierdzony przez właściciela jako `Haniewicz`.
Nie zapisywano poświadczeń w repozytoriach. Materiały podpisu są w Actions
Secrets, a root-owned polecenia `silique/flutter/dart` działają również
w nieinteraktywnym SSH, bez podnoszenia uprawnień i bez restartowania Hermesa.
Szczegóły cofnięcia uprawnień zapisano w dokumentacji Proxmox.
