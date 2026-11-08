#!/usr/bin/env python3
"""App-ID und Stand im App Store ausgeben (für den Link auf der Website). Schlüssel nur aus GitHub-Secrets."""
import json, os, time, urllib.request
import jwt
now = int(time.time())
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                 os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, headers={"Authorization": "Bearer " + tok})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())
for app in get("/v1/apps?limit=20")["data"]:
    a = app["attributes"]
    vers = get(f"/v1/apps/{app['id']}/appStoreVersions?limit=5")["data"]
    st = ", ".join(f"{v['attributes'].get('platform')} {v['attributes'].get('versionString')}: {v['attributes'].get('appStoreState')}" for v in vers)
    print(f"::notice::App {a.get('name')} · Bundle {a.get('bundleId')} · ID {app['id']} · https://apps.apple.com/app/id{app['id']} · {st}")
