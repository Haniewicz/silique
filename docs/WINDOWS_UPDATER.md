# Aktualizator Windows

Od 0.2.32+41 zainstalowana wersja Windows ma w Ustawieniach jawne pobieranie
i uruchamianie aktualizacji. Sprawdzanie dostępności nie uruchamia instalacji.
Klient weryfikuje dotychczasowy podpis Ed25519 manifestu, kanoniczny URL,
rozmiar i SHA256. Natywna granica ponownie sprawdza otwarty plik, jego wersję
i build oraz chroni jego bajty i ścieżkę przez czas używania instalatora.

## Instalator a portable

Obsługiwana jest dokładna instalacja należąca do uruchomionego `silique.exe`:
64-bitowa rejestracja HKLM stałego Inno AppId, rzeczywiście załadowany moduł,
kanoniczny katalog i konserwatywnie chronione ACL. Sama obecność w Program
Files nie wystarcza. Chroniony niestandardowy katalog jest przekazywany do
Setup jawnie; aktualizacja nie tworzy drugiej instalacji domyślnej.

ZIP portable, stare instalacje w AppData, obcy wpis HKCU, nieaktualna
rejestracja, dowiązania i nieobsługiwane ACL pozostają w trybie ręcznym.
Rozpakowana kopia nie uzyskuje prawa do aktualizacji przez istnienie innej
zainstalowanej kopii. ZIP Windows pozostaje publikowany jako opcja przenośna.

## Zapis i anulowanie

Przed natywnym uruchomieniem aplikacja blokuje nowe mutacje i wejście,
drenuje przyjęte operacje, dopuszcza końcowy zapis edytora, blokuje ukryte
klucze i wymaga udanego checkpointu SQLite. Niepotwierdzone zapisy lub zajęty
checkpoint zatrzymują aktualizację. Nie są zmieniane klucze, identyfikatory,
formaty ani lokalizacja notatników.

Anulowanie pobierania nie uruchamia Setup. Odmowa UAC lub nieudane
uruchomienie przywracają dostęp do aplikacji. Po udanym uruchomieniu
instalatora ta decyzja jest nieodwracalna: aplikacja pozostaje zablokowana
i zamyka się. Jeżeli zamknięcie okna się nie powiedzie, dostępne jest wyłącznie
ponowienie zamknięcia, bez kolejnego pobrania lub uruchomienia instalatora.
Anulowanie Setup nie jest anulowaniem pobierania ani dowodem braku zmian.

Instalator nie zabija aplikacji i nigdy nie uruchamia jej z tokenem
administratora. Po zakończeniu należy otworzyć Silique ze zwykłego skrótu.
Instalator nie jest podpisany Authenticode zgodnie z dotychczasową decyzją
właściciela: UAC może pokazać nieznanego wydawcę. Nie pomijamy UAC.

## Granica bezpieczeństwa i ograniczenia

Niezależny pomocnik asInvoker utrzymuje uchwyty pliku, przodków i sekcji
obrazu po zakończeniu aplikacji. Uwierzytelnia rzeczywisty podwyższony proces
główny Inno, nie sam bootstrap ShellExecute. Nie udostępnia dowolnej powłoki
ani poleceń administratora. Szczegóły protokołu, czasu życia i testów:
[windows/updater/README.md](../windows/updater/README.md).

Nieznany stan po uruchomieniu lub błąd uwierzytelnienia pozostawia blokady
zamiast zgadywać, że można wznowić zapis. Osierocona blokada może wymagać
wylogowania albo restartu systemu. Ochrona nie obejmuje administratora,
SYSTEM ani arbitralnego debugowania/zabijania procesów tego samego konta.
Starsze, nieuczestniczące w protokole aplikacje nie mają gwarantowanego
przekazania niezapisanych danych; Setup nie może ich wymuszenie zamknąć.

Natywna akceptacja CI obejmuje rzeczywiste ACL/registry, bariery plików,
negatywną kontrolę słabej blokady, czas życia pomocnika i prawdziwe Inno
aktualizujące ten sam katalog. Dodatkowe testy Dart otwierają rzeczywiste SQLite
z zachowanymi danymi i kluczami. Sztuczny plik ochronny w teście instalatora
nie jest sam w sobie testem bazy SQLite. Podwyższony runner CI nie dowodzi
interaktywnego UAC, UAC z innym administratorem ani działania na urządzeniu
właściciela. Wyniki konkretnych przebiegów są zapisywane w proweniencji wydania.

Operacje poświadczeń, które rozróżniają brak pliku, istniejący katalog i zajętą
blokadę, pobierają wynik oraz kod Win32 atomowo w dołączonej bibliotece
`silique_credential_io.dll`. Osobny odczyt GetLastError w Darcie nie jest
wiarygodny nawet z wiązaniem leaf: aktywność VM pomiędzy wywołaniami może
nadpisać błąd. Most nie zmienia ACL, formatów ani autorytetu magazynu.

Do samodzielnego uruchamiania testów hosta na Windows najpierw zbuduj most:
`cmake -S windows/credentials -B build/credential_native -A x64`, następnie
`cmake --build build/credential_native --config Release`. Builder robi to
przed testami. Normalna aplikacja ładuje DLL wyłącznie obok swojego EXE;
ścieżka builda jest dostępna tylko w środowisku `FLUTTER_TEST=true`.
