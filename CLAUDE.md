# Hinweise für Claude

- Antworten an den Nutzer auf Deutsch.
- Neue Funktion, die Kunden sehen (App), fertig gebaut? Dann zusätzlich ein TikTok-Video anlegen:
  `marketing/tiktok/videos/<id>.json` schreiben (Aufbau siehe `marketing/tiktok/README.md`, nur erfundene Sender/Spiele).
  Der Workflow „TikTok-Videos bauen“ baut daraus automatisch das Video; es erscheint im Admin unter „TikTok-Videos“.
  Jedes Video braucht eine ANDERE Musik: Feld "music" mit einem Stil setzen, den noch kein anderes Video nutzt
  (drama, upbeat, chill, playful, epic, tech, funk, ambient – bei Bedarf in music.py neue Stile ergänzen).
- Die App (www/js/app.js) gibt es auf Deutsch, Englisch und Französisch. Neue Texte, die Kunden sehen, immer so schreiben:
  `T("Deutscher Text")` bzw. mit Werten `Tf("Noch {0} Tage", [n])`, und oben in `I18N_D` den Eintrag
  `"Deutscher Text": ["English", "Français"]` ergänzen. Fehlt der Eintrag, erscheint der deutsche Text.
  Fehlerberichte an den Admin (Report.send …) bleiben deutsch, ohne T().
