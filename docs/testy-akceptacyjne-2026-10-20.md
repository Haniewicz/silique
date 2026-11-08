# Testy właściciela przed wydaniem

Wydanie na GitHubie pozostaje wstrzymane do osobistego sprawdzenia i potwierdzenia przez właściciela. Poniższe pola są przeznaczone do jego testów, niezależnie od wyników testów automatycznych.

Do prób użyj osobnego vaulta „Test funkcji” i kilku przykładowych notatek. Zamknij poprzednią wersję aplikacji przed uruchomieniem paczki testowej.

- [ ] **Wiele notatek:** zaznacz kilka pozycji przyciskiem zaznaczania, a na komputerze również Cmd/Ctrl+klik i Shift+klik. Przenieś je, przypnij, przenieś do kosza i przywróć. Oczekiwany wynik: każda akcja dotyczy wybranych pozycji; Escape anuluje zaznaczenie. Dalsza edycja otwartej notatki zachowuje jej folder i przypięcie.
- [ ] **Podfoldery:** w menu folderu wybierz „Nowy podfolder”. Utwórz trzy poziomy, zwiń i rozwiń drzewko, zamknij i otwórz aplikację. Oczekiwany wynik: hierarchia i puste foldery pozostają zachowane.
- [ ] **Przeciąganie:** na komputerze przeciągnij notatkę, wybraną grupę i folder z podfolderami do innego folderu oraz do katalogu głównego. Spróbuj przenieść folder do własnego podfolderu. Oczekiwany wynik: poprawne przeniesienia zachowują zawartość, niedozwolone nie zmieniają danych. Przeciąganie zdjęć do edytora nadal działa.
- [ ] **Miejsce vaultów:** na nowej instalacji lub osobnym profilu testowym anuluj pierwszy wybór folderu, a następnie wybierz własne miejsce. Utwórz notatkę i otwórz aplikację ponownie. Oczekiwany wynik: zapis jest w wybranej lokalizacji i pozostaje dostępny po restarcie. W dotychczasowej instalacji zachowane są stare dane; zmianę miejsca można sprawdzić w ustawieniach. Nie usuwaj danych dotychczasowej instalacji, żeby wymusić pierwszy start.
- [ ] **Dolny pasek:** sprawdź stany zapisywania, pracy lokalnej, synchronizacji i braku sieci. Oczekiwany wynik: status jest na dolnym pasku obok liczby słów i czasu zmiany; dawny pasek nad toolbarem został usunięty. Wąski widok nie ucina kontrolek.
- [ ] **Nazwa urządzenia:** zmień nazwę bieżącego urządzenia w ustawieniach. Odśwież listę na drugim urządzeniu i uruchom ponownie pierwsze. Oczekiwany wynik: nowa nazwa jest wspólna i trwała, a identyfikator urządzenia oraz jego dostęp pozostają zachowane.
- [ ] **Szukanie w notatce:** wyszukaj frazę występującą kilka razy, użyj Enter, Shift+Enter, strzałek i Escape. Powtórz w trybie źródłowym i zwykłym, także dla polskich znaków oraz frazy bez wyników. Oczekiwany wynik: wszystkie dopasowania są podświetlone, aktywny wynik i licznik się zmieniają, a treść notatki pozostaje bez zmian.
- [ ] **Rozmiar zaznaczenia:** zaznacz słowo, nadaj mu inny rozmiar px, następnie zrób to dla kilku wierszy i cofnij zmianę. Sprawdź zapis, ponowne otwarcie i drugi klient. Oczekiwany wynik: zmienia się tylko wybrany fragment. Bez zaznaczenia nie zmienia się cała notatka.

Dodatkowo przy dwóch urządzeniach sprawdź utworzenie folderu bez sieci, restart, powrót połączenia i równoległą zmianę innego folderu na drugim urządzeniu. Powtórz w chronionym vaulcie. Oczekiwany wynik: lokalne zmiany docierają na drugi klient, a stare nazwy przemianowanych folderów nie wracają.

Po zakończeniu zgłoś znalezione problemy albo wyraźnie potwierdź zgodę na przygotowanie wydania GitHub. Sam brak zgłoszeń nie jest potwierdzeniem.
