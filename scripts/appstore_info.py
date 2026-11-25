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
    vers = get(f"/v1/apps/{app['id']}/appStoreVersions?limit=12")["data"]
    st = ", ".join(f"{v['attributes'].get('platform')} {v['attributes'].get('versionString')}: {v['attributes'].get('appStoreState')}" for v in vers)
    print(f"::notice::App {a.get('name')} · Bundle {a.get('bundleId')} · ID {app['id']} · https://apps.apple.com/app/id{app['id']} · {st}")
    try:
        av = get(f"/v1/apps/{app['id']}/appAvailabilityV2")
        avid = av["data"]["id"]
        terr, url = [], f"/v2/appAvailabilities/{avid}/territoryAvailabilities?limit=200&include=territory"
        while url:
            d = get(url)
            for t in d.get("data", []):
                tid = (t.get("relationships", {}).get("territory", {}).get("data") or {}).get("id")
                terr.append((tid, t["attributes"].get("available"), t["attributes"].get("contentStatuses")))
            nxt = d.get("links", {}).get("next")
            url = nxt.replace("https://api.appstoreconnect.apple.com", "") if nxt else None
        on = [x[0] for x in terr if x[1]]
        tur = [x for x in terr if x[0] == "TUR"]
        print(f"::notice::Länder: {len(on)} von {len(terr)} freigegeben · Türkei: {tur} · Deutschland: {[x for x in terr if x[0] == 'DEU']}")
    except Exception as e:
        print(f"::warning::Länder nicht lesbar: {e}")
    tv = get(f"/v1/apps/{app['id']}/appStoreVersions?filter[platform]=TV_OS&limit=3")["data"]
    print("::notice::Apple TV: " + ", ".join(f"{v['attributes'].get('versionString')}: {v['attributes'].get('appStoreState')} (Veröffentlichung: {v['attributes'].get('releaseType')})" for v in tv))
    for plat in ("IOS", "TV_OS"):
        try:
            bl = get(f"/v1/builds?filter[app]={app['id']}&filter[preReleaseVersion.platform]={plat}&sort=-uploadedDate&limit=3"
                     f"&include=preReleaseVersion,buildBetaDetail&fields[builds]=version,processingState,uploadedDate,expired,preReleaseVersion,buildBetaDetail")
            inc = {(x["type"], x["id"]): x["attributes"] for x in bl.get("included", [])}
            for b in bl["data"]:
                pr = b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}
                bd = b.get("relationships", {}).get("buildBetaDetail", {}).get("data") or {}
                ver = inc.get(("preReleaseVersions", pr.get("id")), {}).get("version", "?")
                beta = inc.get(("buildBetaDetails", bd.get("id")), {})
                print(f"::notice::{plat} Build {ver} ({b['attributes'].get('version')}) · {b['attributes'].get('processingState')}"
                      f" · hochgeladen {(b['attributes'].get('uploadedDate') or '')[:16]} · TestFlight extern: {beta.get('externalBuildState')}"
                      f"{' · abgelaufen' if b['attributes'].get('expired') else ''}")
        except Exception as e:
            print(f"::warning::{plat} Builds: {e}")
