# Updater — weryfikacja 2026-10-20

Kandydat: 0.2.5+9, lokalne paczki `Wydania/0.2.5-kandydat/podpisane-wydanie`.
Publiczny kanał nadal ma 0.2.4+8. Repo aplikacji i serwera potwierdzono jako prywatne; repo dystrybucji jako publiczne. W repo dystrybucji są wyłącznie README, latest.json i appcast.xml. Release zawiera tylko APK, ZIP i SHA256SUMS.

- `flutter analyze`: No issues found.
- `flutter test`: 96 passed, 10 skipped (9 serwerowych, 1 publiczny test sieci).
- Osobno `SILIQUE_PUBLIC_UPDATER_SMOKE=1 flutter test test/updater_public_smoke_test.dart`: 1 passed; rzeczywisty kanał i pełny publiczny APK bez uwierzytelnienia.
- Izolowany Android 15: ręczne sprawdzanie w produkcyjnym buildzie 9, następnie osobna aplikacja testowa bez dostępu do kluczy/notatek; odrzucono złą ścieżkę, obcy certyfikat, równy versionCode; systemowe ustawienia zgody i Package Installer zainstalowały debug build 10 nad testowym 7. Kontrolny plik danych zachowano. Testowego emulatora usunięto; istniejących emulatorów ani danych właściciela nie zmieniano.
- Test edytora dla zmian dopisanych podczas blokowanego zapisu: pozytywny po poprawce, negatywny bez poprawki (utrata ostatniego tytułu). Zapobiega zamknięciu przez instalator przed zapisaniem ostatniej generacji.
- macOS release + Android release: udane, jawny `--target=lib/main.dart`, wersja 0.2.5 build 9. Paczki testowej sondy/debug build 10 nie są dystrybuowane.
- macOS `codesign --verify --deep --strict`: aplikacja, Sparkle.framework, Installer.xpc, Downloader.xpc, Autoupdate, Updater.app poprawne; helpery mają Hardened Runtime. Sandbox aplikacji i dokładne wyjątki Mach lookup zachowane; nieużywany Downloader.xpc zachowuje entitlements oficjalnego Sparkle 2.10.0. Główne binaria mają arm64 + x86_64.
- Android `apksigner verify`: v2 RSA4096, ten sam certyfikat SHA256 co 0.2.4. applicationId i versionCode poprawne, brak `application-debuggable`.
- `prepare_update.py` potwierdził tożsamości, wersje i certyfikat Androida oraz podpisał metadane i archiwum. Dart zweryfikował manifest kluczem wbudowanym w aplikację; narzędzie Sparkle zweryfikowało podpis XML.
- `publish_update.py`: ponowny przebieg dla zatwierdzonego 0.2.4 jest idempotentny; weryfikuje również zgodność appcastu z manifestem i podpis archiwum. Nie uruchamiano publikacji 0.2.5.

Pełna instalacja i restart przez Sparkle na rzeczywistej aplikacji macOS pozostają do ręcznego testu. Nie wykonywano tego na danych właściciela. Nie uruchamiano GitHub Actions ani nie zmieniano serwera synchronizacji.

## SHA256 kandydata

- `3d63c6739c6d78beefa0dcc7a84606be38b37180542c13f2cdd3703c71a10ec3` — `Silique-0.2.5-macOS.zip`
- `4111162eebd56fe7f4416261c377aadd5e3e5b3e08f7e41b95210400af14325e` — `Silique-0.2.5.apk`
