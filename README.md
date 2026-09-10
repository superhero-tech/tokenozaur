# Tokenozaur 🦖

> **Alpha · 0.4.0-alpha.1**
> Działa na prawdziwych logach Codexa i Claude Code, ale formaty tych logów nie są publicznym, stabilnym API. Przed użyciem wyników w benchmarku sprawdź je na kontrolowanej sesji.

Tokenozaur to natywna aplikacja do paska menu macOS. Monitoruje lokalne, interaktywne sesje Codexa i Claude Code, pokazuje zużycie tokenów oraz przelicza je na koszt według cennika API.

Nie wysyła logów do chmury. Własna baza przechowuje wyłącznie metadane użycia — bez promptów, odpowiedzi i treści wywołań narzędzi.

## Co potrafi

- automatycznie wykrywa aktywne sesje Codex Desktop, Codex CLI, Claude Code Desktop i Claude Code CLI;
- pokazuje tokeny i koszt od ostatniego wznowienia oraz dla całego wątku;
- rozbija usage na uncached input, cache read/write, output i reasoning/thinking;
- rozpoznaje tryb Codexa Standard/Fast i stosuje właściwy mnożnik;
- sumuje zużycie dla dzisiaj, 7 dni, miesiąca i roku;
- pokazuje miesięczny wykres Codex vs Claude Code na wspólnej skali;
- archiwizuje sesje lokalnie, dzięki czemu statystyki zostają po usunięciu źródłowego JSONL;
- obsługuje kontrolowane benchmarki z `RUN_ID` i checkpointami;
- eksportuje wyniki jako CSV, Markdown lub JSON;
- animuje dinozaura w pasku menu, gdy aktywna sesja zjada kolejne tokeny.

## Prywatność

Tokenozaur czyta wyłącznie lokalne pliki:

- Codex: `~/.codex/sessions/**/*.jsonl` i `~/.codex/archived_sessions/*.jsonl`;
- Claude Code: `~/.claude/projects/**/*.jsonl`.

W archiwum zapisuje dostawcę, model, sesję, projekt/katalog roboczy, datę, klasy tokenów, tier cenowy, wyliczony koszt oraz identyfikatory potrzebne do deduplikacji. Nie zapisuje treści rozmów.

## Instalacja z kodu

Wymagania:

- macOS 13 lub nowszy;
- Swift 5.10+ i Xcode Command Line Tools;
- lokalne logi Codexa lub Claude Code.

Zbuduj i spakuj aplikację:

```bash
zsh Scripts/package_app.sh
```

Gotowy bundle znajdziesz w `.build/Tokenozaur.app`. Instalacja lokalna:

```bash
cp -R .build/Tokenozaur.app /Applications/
open /Applications/Tokenozaur.app
```

Aplikacja jest podpisywana ad hoc. Działa wyłącznie w pasku menu i nie pojawia się w Docku.

## Weryfikacja

Uruchom self-testy:

```bash
SWIFT_EXEC="$PWD/Scripts/swiftc_compatible.sh" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift run --disable-sandbox TokenozaurSelfTest
```

Pakiet alpha ma 84 testy obejmujące między innymi:

- Codex parent/child, nested children, guardian i replay;
- aktywne oraz archiwalne sesje Codexa;
- Claude sidechain i deduplikację wiadomości;
- rozróżnienie Desktop, CLI i automatyzacji;
- Standard/Fast oraz wspierane modele Claude;
- trwałość SQLite, zmianę cennika i brak podwójnego naliczania;
- granicę wznowienia po 30 minutach;
- migrację danych z poprzedniej nazwy Tokenożerca;
- kompatybilność zapisanych runów 0.3;
- odporność czytnika na uszkodzone i bardzo duże linie JSONL.

Fixture’y są syntetyczne i nie zawierają prawdziwych rozmów.

Przydatny jest także tekstowy probe:

```bash
swift run --disable-sandbox TokenozaurProbe
swift run --disable-sandbox TokenozaurProbe periods
swift run --disable-sandbox TokenozaurProbe codex /ścieżka/do/sesji.jsonl
```

## Jak działa monitorowanie

1. Tokenozaur odnajduje interaktywne root sessions obu dostawców.
2. Parser zachowuje provenance każdego requestu.
3. Normalizer usuwa replay rodzic–dziecko Codexa i kopie parent message w sidechainach Claude.
4. Pricing engine liczy API-equivalent cost ze wskazanego snapshotu stawek.
5. SQLite przechowuje znormalizowane metadane usage i zasila zestawienia okresowe.

Sesja jest aktywna przez 30 minut od ostatniego wpisu. Następna wiadomość po tej przerwie rozpoczyna nowy blok „od ostatniego wznowienia”. Panel jest odświeżany co 10 sekund, gdy jest otwarty, i co 60 sekund w tle.

## Dane lokalne

Tokenozaur zapisuje dane w:

```text
~/Library/Application Support/Tokenozaur/
├── usage-archive.sqlite
├── session-history-cache.json
└── runs.json
```

Przy pierwszym uruchomieniu po zmianie nazwy cały katalog `~/Library/Application Support/Tokenozerca/` jest automatycznie przenoszony do `Tokenozaur/`. Jeśli migracja się nie powiedzie, aplikacja nadal użyje starego katalogu, żeby nie zgubić historii.

## Kontrolowany benchmark

1. Rozwiń w aplikacji `Benchmark kontrolowany`.
2. Nadaj pomiarowi nazwę i wybierz dostawcę.
3. Kliknij `Rozpocznij i skopiuj RUN_ID`.
4. Wklej identyfikator na początku promptu w nowej sesji Codexa lub Claude Code.
5. Zapisz checkpointy `Pierwszy wynik` i `Zaakceptowany`.
6. Zakończ run i wyeksportuj wynik.

Zwykłe monitorowanie nie wymaga tworzenia runu ani wklejania identyfikatora.

## Cennik

Wersja alpha zawiera zamrożony snapshot `webinar-2026-09-02-v2` dla:

- `gpt-5.6-sol`;
- `claude-fable-5-1` i `claude-fable-5`;
- `claude-opus-5` i `claude-opus-4-8`;
- `claude-sonnet-5`;
- `claude-haiku-4-5`.

Nieznany model otrzymuje status `unavailable` zamiast zmyślonej ceny. Nieznany tier Codexa zachowuje dolną granicę Standard i oznacza wynik jako `partial`.

## Ograniczenia wersji alpha

- Kwota jest ekwiwalentem cennika API, a nie rzeczywistą opłatą za abonament.
- Nieujawnione opłaty za narzędzia nie są doliczane.
- Już usuniętych rekordów usage nie da się odzyskać z samego `~/.claude/history.jsonl`.
- Aktywna sesja jest ponownie analizowana od początku; ekstremalnie długie wątki mogą być kosztowne obliczeniowo.
- Automatyzacje Claude `sdk-*` oraz Codex `codex_exec`, SDK i ACP są celowo wyłączone ze statystyk osobistego użycia.
- Zmiana lokalnego formatu JSONL przez dostawcę może wymagać aktualizacji parsera.

## Status projektu

To jest **alpha**, nie stabilne wydanie. Najważniejsze przed wersją beta: inkrementalny parser bardzo długich sesji, automatyczne testy na kolejnych realnych formatach logów oraz podpisany i notarized build macOS.
