# TibberPrice

Menüleisten-App für macOS: zeigt den aktuellen Tibber-Strompreis pro **15 Minuten**
(Viertelstunde) und beim Klick einen Preisverlauf für heute / morgen / 2 Tage.

Datenquelle: Tibber GraphQL `https://api.tibber.com/v1-beta/gql`,
`priceInfo(resolution: QUARTER_HOURLY)`.

## Bauen & starten

```sh
./build.sh
```

Baut `TibberPrice.app` (ad-hoc signiert) und startet sie. Kein Xcode-Projekt, keine Dependencies.
Beim ersten Start Token einfügen (developer.tibber.com → Token). Der Token liegt nur in der Keychain.

## Funktionen

- Menüleiste: aktueller Preis, z. B. `29,5 ct`. Klick öffnet das Popover,
  optional schon beim Drüberfahren (Einstellungen).
- Einstellungen: „Beim Anmelden starten" (SMAppService), „Beim Drüberfahren öffnen".
- Popover: Ring mit aktuellem Preis und Viertelstunde, Durchschnittspreis des Zeitraums,
  15-Minuten-/60-Minuten-Umschalter, Heute / Morgen / 2 Tage, Flächenchart mit
  Jetzt-Markierung.
- **Hover** über das Chart: Tooltip mit Preis und Zeitfenster (`Morgen, 05:30 – 05:45`) plus
  Fadenkreuz am Preis.
- Farbe aus der relativen Lage im sichtbaren Zeitraum (türkis = günstig, orange/rot = teuer),
  nicht aus dem `level` der API — das ist bei Viertelstundenwerten inkonsistent.
- **Kein Passwort-/Touch-ID-Dialog**: Token liegt in `~/Library/Application Support/TibberPrice/token`
  mit Rechten `0600` (bewusst Datei statt Keychain — Keychain-Einträge einer ad-hoc signierten
  App fragen nach jedem Build erneut nach dem Passwort). Wird einmal pro Start gelesen.
- Cache: `~/Library/Application Support/TibberPrice/cache.json`, wird 6 h genutzt
  (Preise ändern sich nur 1×/Tag, schont das Tibber-Rate-Limit von 100 req/5 min).
- Aktualisierung: nach jeder Viertelstunde; Netzabruf nur bei veraltetem Cache.

## CLI (im App-Bundle)

```sh
./TibberPrice.app/Contents/MacOS/TibberPrice --selfcheck   # Parsing/Formatierung/Aggregation prüfen
./TibberPrice.app/Contents/MacOS/TibberPrice --preview     # Popover als /tmp/tibber-preview.png rendern
./TibberPrice.app/Contents/MacOS/TibberPrice --set-token <token>   # Token in die Keychain legen
```

## Hinweise

- Kein Login-Item, keine Preis-Alarme, keine Notifications.
