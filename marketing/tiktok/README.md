# TikTok-Baukasten

Eine Datei in `videos/` beschreibt ein Video. GitHub baut daraus automatisch (Workflow „TikTok-Videos bauen“):

- `<id>.mp4` – mit eigener, lizenzfreier Musik (`music.py`)
- `<id>-ohne-musik.mp4` – für einen TikTok-Sound
- `<id>.txt` – Beschreibung, imperumtv.xyz und Hashtags

Die Dateien landen in der Vorab-Version **tiktok** und erscheinen im Admin unter „TikTok-Videos“.

## Aufbau einer Beschreibung

```json
{
  "id": "name-ohne-leerzeichen", "title": "Titel im Admin", "version": "1.0.293",
  "hook":   { "h": "Große Überschrift<br>mit Zeilenumbruch", "s": "Unterzeile", "art": { ... } },
  "scenes": [ { "h": "…", "s": "…", "art": { ... } } ],
  "end":    { "h": "Schlusssatz", "s": "Zeile darunter" },
  "caption": "Text für TikTok", "hashtags": "#firetvstick …"
}
```

Bilder (`art`):
- `{"type":"tv","screen":"pitch|movie|black","badge":"Sendername","toast":"Hinweis","toastAt":1.2,"blackFrom":0.9,"blackTo":2}`
- `{"type":"phone","title":"…","ok":"grüner Kasten","screen":"pitch","rows":[["links","rechts"]]}`
- `{"type":"cards","items":[{"t":"Titel","v":"Zeile","ok":true,"icon":"★"}]}`
- `{"type":"big","text":"482 913","small":"Unterschrift"}`

Zeitplan: Intro 2,6 s, jede Szene 3,6 s, Abschluss 3 s. Nur erfundene Sender und Spiele verwenden.
Lokal bauen: `node build.js videos/<name>.json ../../out` (braucht Playwright, ffmpeg, Python mit numpy/scipy).
