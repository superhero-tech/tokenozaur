# Tokenożerca

Natywna aplikacja macOS Menu Bar, która czyta lokalne logi Codex Desktop i Claude Desktop, mierzy tokeny oraz oblicza API-equivalent cost według zamrożonego katalogu cen.

## Build

```bash
SWIFT_EXEC="$PWD/Scripts/swiftc_compatible.sh" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift run --disable-sandbox TokenozercaSelfTest
zsh Scripts/package_app.sh
```

Gotowa aplikacja powstaje jako `.build/Tokenożerca.app`.

Wersja MVP jest także zainstalowana jako `/Applications/Tokenożerca.app`. Po uruchomieniu działa wyłącznie jako ikona `🦖` w pasku menu i nie pojawia się w Docku.

## Źródła danych

- Codex Desktop: `~/.codex/sessions/**/*.jsonl`
- Claude Desktop: `~/.claude/projects/**/*.jsonl`

Tokenożerca otwiera te pliki wyłącznie do odczytu. Nie wysyła transkryptów ani metadanych przez sieć.

## Automatyczne monitorowanie

1. Kliknij ikonę `🦖` w pasku menu.
2. Tokenożerca automatycznie pokaże root sessions Codex Desktop i Claude Desktop aktualizowane w ostatnich 30 minutach.
3. Każda karta pokazuje tokeny i API-equivalent cost od ostatniego wznowienia. Po rozwinięciu widać również sumę całego wątku, model oraz podział na input, cache, output i reasoning/thinking.
4. Lista odświeża się co 5 sekund. Niezmienione pliki korzystają z ostatniego wyliczenia.

Nie trzeba rozpoczynać pomiaru ani wklejać `RUN_ID`, aby zobaczyć koszt zwykłej rozmowy.

Sesja znika z aktywnej listy po 30 minutach bez nowych wpisów w logu. Następna wiadomość po tej przerwie rozpoczyna nowy blok `Od ostatniego wznowienia`.

## Zużycie w czasie

Panel `Zużycie` sumuje tokeny i koszt obu narzędzi dla czterech nakładających się okresów: dzisiaj, ostatnie 7 dni wraz z dzisiaj, bieżący miesiąc i bieżący rok. Usage jest przypisywany do timestampu konkretnej odpowiedzi, więc wznowienie starego wątku nie przypisuje całej jego historii do bieżącego dnia.

## Benchmark kontrolowany

1. Kliknij ikonę `🦖` w pasku menu.
2. Rozwiń `Benchmark kontrolowany`, podaj nazwę i wybierz dostawcę.
3. Kliknij `Rozpocznij i skopiuj RUN_ID`.
4. Otwórz nową rozmowę w aplikacji desktopowej i wklej identyfikator na początku promptu.
5. Tokenożerca automatycznie dołączy nowy plik sesji. W razie potrzeby użyj ręcznego `Dołącz`.
6. Zapisz checkpointy `Pierwszy wynik` i `Zaakceptowany`, następnie zakończ pomiar.

Runy są zapisywane lokalnie w `~/Library/Application Support/Tokenozerca/runs.json`, dlatego niedokończony pomiar może zostać wznowiony po ponownym uruchomieniu aplikacji.

## Wspierany cennik MVP

- `gpt-5.6-sol`
- `claude-opus-5`

Snapshot stawek ma identyfikator `webinar-2026-09-02-v1`. Nieznany model otrzymuje status `unavailable` i nie dostaje kwoty zastępczej.

## Znane ograniczenia

- Przed webinarem trzeba wykonać świeży kontrolowany run z jednym subagentem w każdej aplikacji oraz ręczny dry run całego interfejsu.
- Automatyczne sesje nie są jeszcze kopiowane do własnej trwałej bazy. Panel okresowy rekonstruuje historię z lokalnych logów dostawców; osobna baza, filtrowanie i późniejsze przeliczanie pozostają zaplanowanym kolejnym etapem.
- Nieujawnione opłaty za narzędzia nie są doliczane; raport mówi o tym wprost.
- Aplikacja co 5 sekund ponownie analizuje przypięte pliki. Jest to wystarczające dla obecnych logów, ale bardzo duże, wielodniowe sesje mogą wymagać później odczytu przyrostowego.
- Format lokalnych logów dostawców nie jest publicznym, stabilnym API. Zmiana formatu może wymagać aktualizacji parsera.

## Granica interpretacji

Wyświetlana kwota jest kosztem tokenów według publicznego cennika API. Nie jest dodatkowym obciążeniem abonamentu. Nieujawnione opłaty za narzędzia są wskazywane jako nieuwzględnione.
