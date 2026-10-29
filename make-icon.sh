#!/bin/sh
# Baut aus AppIcon.png den Symbol-Katalog, den Xcode erwartet
set -e
mkdir -p Assets.xcassets/AppIcon.appiconset
cp AppIcon.png Assets.xcassets/AppIcon.appiconset/AppIcon.png
cat > Assets.xcassets/Contents.json <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > Assets.xcassets/AppIcon.appiconset/Contents.json <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# Freigestelltes Logo für die Startseite (ohne Hintergrund)
mkdir -p Assets.xcassets/Logo.imageset
cp logo-frei.png Assets.xcassets/Logo.imageset/logo-frei.png
cat > Assets.xcassets/Logo.imageset/Contents.json <<'JSON'
{
  "images" : [ { "filename" : "logo-frei.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
