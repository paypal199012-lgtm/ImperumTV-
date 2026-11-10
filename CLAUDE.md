# Hinweise für Claude

- Antworten an den Nutzer auf Deutsch.
- Neue Funktion, die Kunden sehen (App), fertig gebaut? Dann zusätzlich ein TikTok-Video anlegen:
  `marketing/tiktok/videos/<id>.json` schreiben (Aufbau siehe `marketing/tiktok/README.md`, nur erfundene Sender/Spiele).
  Der Workflow „TikTok-Videos bauen“ baut daraus automatisch das Video; es erscheint im Admin unter „TikTok-Videos“.
  Jedes Video braucht eine ANDERE Musik: Feld "music" mit einem Stil setzen, den noch kein anderes Video nutzt
  (drama, upbeat, chill, playful, epic, tech, funk, ambient – bei Bedarf in music.py neue Stile ergänzen).
