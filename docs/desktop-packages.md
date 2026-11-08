# Wydania Windows i Linux GTK4

Aktualne wydanie: [0.2.8+17](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.8), opublikowane 2026-10-22 na polecenie właściciela. Poprawki importu, edycji i synchronizacji; [wyniki końcowych prób wszystkich platform](0.2.8.md). Poniższy opis prób 0.2.5 zachowano jako historię budowania.

Wydanie 0.2.5+10 opublikowano 2026-10-21 po potwierdzeniu właściciela: [publiczne instalatory](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.5). Wcześniejszy kandydat macOS/Android 0.2.5+9 pozostaje zachowany oddzielnie. Starsze publiczne wydanie 0.2.4 pozostało bez zmian.

## Windows x64

`tool/build_windows.ps1` uruchamia test integracyjny prawdziwego magazynu kluczy, SQLite i edytora. Test działa w trybie diagnostycznym, ponieważ potrzebuje VM service. Następnie projekt jest czyszczony i osobno budowany z produkcyjnego `lib/main.dart`. Pakiety zawierają lokalne biblioteki Visual C++ runtime.

Wyniki: instalator Inno Setup EXE na użytkownika, przenośny ZIP, SHA256 oraz raport. Procedura instaluje prawdziwy EXE, porównuje pliki, sprawdza otwarcie okna produkcyjnej aplikacji i wykonuje deinstalację w jednorazowym środowisku. Nie kasuje katalogów vaultów przy deinstalacji.

Publiczny workflow `Haniewicz/silique-releases/.github/workflows/windows.yml` uruchamia się wyłącznie ręcznie z pełnym SHA prywatnego kodu. Standardowy `windows-latest`, bez cache, artefakty przechowywane jeden dzień. Osobny read-only deploy key i osobny publiczny certyfikat diagnostyczny; żaden token źródłowego repo nie trafia do aplikacji. Logi kompilatora są szyfrowane przed wysłaniem. Workflow nie tworzy GitHub Release.

Pierwsza próba 39546079311 została zatrzymana przed przydzieleniem runnera: `account is locked due to a billing issue`. Po odblokowaniu Actions próba [39552748291](https://github.com/Haniewicz/silique-releases/actions/runs/39552748291) zakończyła się sukcesem. Kod `04c6696de810dbdf97a027baf55f1c2f5ca7fad6`: natywny test SQLite, magazynu kluczy, edytora i zaszyfrowanego vaulta zaliczony; instalacja EXE, zgodność plików, start produkcyjnego okna i deinstalacja zaliczone. Pobranie oraz SHA256 obu artefaktów zweryfikowano lokalnie. ZIP zawiera wymagany runtime i zasoby, bez źródeł ani PDB. Późniejsza zmiana `NativeWindow` dotyczy wyłącznie pozycjonowania okna na Linux/Wayland.

## Linux GTK4 — DEB oraz RPM dla Fedory

Oficjalny Flutter 3.47.7 nadal używa GTK3. Ta gałąź korzysta z osobnego silnika GTK4, opartego na publicznym eksperymentalnym porcie `richyo-codes/flutter` (`issue-94804-gtk4-linux`, `11ed8f4418f3fa014ed5c79c7c01f75054248468`). Port przeniesiono na oficjalny Flutter 3.47.7 (`abaf9c523780a608bd46686fd5e53740a07077f8`), z Dart 3.13.5. Nie obniżono wymagań edytora ani zależności aplikacji. Nie zmieniono globalnego SDK ani runnerów pozostałych systemów. GTK4 pozostaje wsparciem eksperymentalnym.

Powtarzalny patch: `tool/gtk4/flutter-3.47.7-gtk4.patch`; tworzenie oddzielnego SDK: `tool/bootstrap_linux_gtk4.sh`. Wymaga Ubuntu 24.04 x64 z clang, cmake, ninja, GTK4/GTK3 development headers, libsecret, jsoncpp, bibliotekami graficznymi oraz depot_tools `1eb46f8b23b4c6b3caa2be8e05999b6d1f4d0253`. Pobrane zależności silnika są przypięte przez DEPS. `depot_tools` nie aktualizuje się podczas odtwarzania kompilacji.

Runner `linux-gtk4/` i wynik `build/linux-gtk4/` są niezależne od standardowego Linux GTK3. `tool/prepare_linux_gtk4.py` kopiuje przypięte adaptery do lokalnego katalogu kompilacji; nie modyfikuje wspólnego cache pakietów. Własne adaptery obejmują wybór plików, przeciąganie plików, okno, monitory i otwieranie adresów. Libsecret zachowuje dotychczasowy protokół magazynu kluczy.

Budowanie na jednorazowym builderze:

```sh
SILIQUE_GTK4_SDK=/sciezka/flutter-gtk4-stable \
SILIQUE_FEDORA_ROOTFS=/sciezka/fedora44/rootfs \
bash tool/build_linux_gtk4.sh
```

Rootfs Fedory 44 pochodzi z `registry.fedoraproject.org/fedora:44`, rozpakowanego przez skopeo/umoci bez uruchamiania demona kontenerów. Wewnątrz wymagane są `rpm-build`, GTK4, libsecret i biblioteki renderowania. Do uruchamiania używany jest PRoot 5.5.0 (`25dc6a3134891f98a79f57ce1c2c1b23ff15cad1`), ponieważ Ubuntu 24.04 dostarcza starszy PRoot 5.1 bez obsługi nowych procesów `clone3`. Ustaw `SILIQUE_PROOT` na nowe binarium. Pakowanie wymaga również `patchelf`: usuwa ścieżki kompilacji zachowane przez Flutter w kopiowanych bibliotekach. RPM budowany jest narzędziami Fedory. Osobne próby instalacji i uruchomienia mają potwierdzić zależności Fedory, a nie tylko poprawność formatu RPM.

Produkcyjny probe AOT zapisuje wyłącznie do losowego katalogu tymczasowego i używa prefiksu własnych wpisów w prawdziwym Secret Service. Sprawdza okno, wersję, zapis edytora, prawdziwe wpisywanie z klawiatury, wybór/anulowanie folderu, przeciągnięcie obrazu z innego programu GTK4, odmowę zamknięcia po błędzie zapisu, SQLite oraz ponowne odblokowanie zaszyfrowanego vaulta. Probe nie wymaga VM service. Następnie skrypt ponownie buduje produkcyjny `lib/main.dart` i wymaga innego skrótu `libapp.so`.

Pakowanie wymaga udanego raportu probe i sprawdza zależności każdego ELF przez `ldd`: obecność GTK4, brak GTK3 i brak nierozwiązanych bibliotek. Wyniki: DEB dla Ubuntu 24.04+, RPM dla Fedory 44 oraz archiwum tar.gz. Pakiety instalują aplikację w `/opt/silique`, skrót w menu oraz `/usr/bin/silique`; vaulty wybiera użytkownik. Biblioteki GTK i systemowy Secret Service pochodzą z dystrybucji.

## Weryfikacja kandydata

- Analiza kodu aplikacji: bez uwag. Testy aplikacji: 97 zaliczonych, 10 pominiętych (wymagających osobnego serwera lub wywołania testu rzeczywistego kanału).
- 70 źródeł warstwy GTK4 silnika: sprawdzenie składni, właściwa kompilacja i linkowanie GTK4 zaliczone. W porcie uzupełniono przekazywanie klawiatury/IME, sygnały zamykania i listy monitorów, a także zwalnianie EGLImage po odłączeniu bieżącego kontekstu. Zamknięciem notatnika zarządza natywny callback zapisu aplikacji.
- Sześć adapterów systemowych: kompilacja, linkowanie oraz opisane wyżej próby natywne zaliczone.
- Przeniesione narzędzia Fluttera: analiza bez błędów; test izolacji ścieżek GTK3/GTK4 i flavorów zaliczony.
- Pełne linkowanie GTK4, test aplikacji AOT, instalacja DEB i RPM oraz uruchomienie zainstalowanej aplikacji w Ubuntu 24.04 i Fedorze 44 przeszły. Pełny test edytora, klawiatury, folderu, przeciągania obrazu i szyfrowanego vaulta przeszedł także z bibliotekami Fedory 44. Po poprawce pozycjonowania okna przeszedł także test AOT na headless Weston/Wayland (bez DISPLAY i bez fallbacku X11): okno, zapis, SQLite, magazyn kluczy, błąd zapisu zatrzymujący zamknięcie oraz ponowne odblokowanie chronionego vaulta. Końcowe DEB/RPM z tymi poprawkami ponownie zainstalowano i uruchomiono w obu systemach. Pełna interakcja klawiatury/dialogów/drop była automatyzowana w X11; fizyczna sesja GNOME/Wayland pozostaje częścią osobistego testu właściciela.

W historycznym 0.2.5 Windows/Linux miały ręczne aktualizacje ze strony publicznych wydań. Od 0.2.7 pakiety RPM/DEB mogą aktualizować się z aplikacji po systemowej autoryzacji; pierwsze przejście z 0.2.6 wymaga ręcznej instalacji. Automatyczny instalator w aplikacji pozostaje dostępny na macOS i Androidzie. Identyfikatory instalacji i kluczy `nova.*` są zachowane.

Instalatory Windows nie mają podpisu Authenticode, a RPM nie ma podpisu OpenPGP. Podpis Ed25519 kanału aktualizacji obejmuje adresy, rozmiary i SHA256 paczek. macOS zachowuje lokalny podpis bez notaryzacji; APK ma dotychczasowy certyfikat wydania.
