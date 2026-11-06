#!/usr/bin/env python3
"""
ImperumTV: öffentlichen TestFlight-Link einrichten (App Store Connect API).

  1. neuesten fertig verarbeiteten iPhone-Build suchen
  2. Angaben für die Beta-Prüfung übernehmen (Kontakt aus den App-Prüfungs-Angaben der App)
  3. Gruppe „Öffentlich“ mit öffentlichem Link anlegen bzw. einschalten, Build hinzufügen
  4. Build zur Beta-Prüfung bei Apple einreichen
  5. öffentlichen Link ausgeben

Schlüssel kommen nur aus Umgebungsvariablen (GitHub-Secrets) und werden nie ausgegeben.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com"
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
P8 = os.environ["ASC_KEY_P8"]
BUNDLE = os.environ.get("BUNDLE_ID") or "tv.imperum.app"
GROUP = "Öffentlich"
WHATS_NEW = os.environ.get("WHATS_NEW") or (
    "Neueste ImperumTV-Version mit der neuen Oberfläche (wie auf Android). "
    "Bitte testen: Wiedergabeliste laden, Live-TV, Filme und Serien.")
DESCRIPTION = ("ImperumTV ist ein Player für eigene IPTV-Wiedergabelisten. "
               "Die App enthält selbst keine Sender oder Inhalte.")


def note(msg):
    print("::notice::" + msg, flush=True)


def fail(msg):
    print("::error::" + msg, flush=True)
    sys.exit(1)


_tok = {"t": None, "at": 0}


def token():
    if not _tok["t"] or time.time() - _tok["at"] > 600:
        now = int(time.time())
        _tok["t"] = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                               P8, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})
        _tok["at"] = time.time()
    return _tok["t"]


def call(method, path, body=None, ok=(200, 201, 204)):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            data = json.loads(raw)
        except Exception:
            data = {"raw": raw.decode(errors="replace")[:500]}
        if e.code in ok:
            return e.code, data
        return e.code, data


def must(method, path, body=None, what=""):
    st, data = call(method, path, body)
    if st not in (200, 201, 204):
        errs = "; ".join((x.get("title", "") + ": " + x.get("detail", "")) for x in data.get("errors", [])) or str(data)[:400]
        fail(f"{what or path} → HTTP {st}: {errs}")
    return data


# ---------- 1. App und Build ----------
apps = must("GET", f"/v1/apps?filter[bundleId]={BUNDLE}", what="App suchen")["data"]
if not apps:
    fail(f"Keine App mit der Bundle-ID {BUNDLE} gefunden")
app_id = apps[0]["id"]
print("App:", apps[0]["attributes"].get("name"), flush=True)

build = None
for _ in range(30):  # bis zu 15 Minuten warten, falls gerade noch verarbeitet wird
    blds = must("GET", f"/v1/builds?filter[app]={app_id}&filter[preReleaseVersion.platform]=IOS"
                       f"&sort=-uploadedDate&limit=5&fields[builds]=version,processingState,expired,usesNonExemptEncryption,uploadedDate",
                what="Builds")["data"]
    if not blds:
        fail("Noch kein iPhone-Build in App Store Connect")
    newest = blds[0]
    stt = newest["attributes"].get("processingState")
    if stt == "VALID" and not newest["attributes"].get("expired"):
        build = newest
        break
    if stt in ("FAILED", "INVALID"):
        fail(f"Neuester Build {newest['attributes'].get('version')} ist {stt}")
    print("Build", newest["attributes"].get("version"), "wird noch verarbeitet …", flush=True)
    time.sleep(30)
if not build:
    fail("Build ist nach 15 Minuten noch nicht fertig verarbeitet – später erneut starten")
build_id = build["id"]
build_no = build["attributes"].get("version")
print("Build:", build_no, flush=True)

if build["attributes"].get("usesNonExemptEncryption") is None:
    # Nur HTTPS (Info.plist: ITSAppUsesNonExemptEncryption = false)
    must("PATCH", f"/v1/builds/{build_id}",
         {"data": {"type": "builds", "id": build_id, "attributes": {"usesNonExemptEncryption": False}}},
         what="Export-Angabe")

# ---------- 2. Angaben für die Beta-Prüfung ----------
contact = {}
vers = must("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=1", what="App-Version")["data"]
if vers:
    st, rd = call("GET", f"/v1/appStoreVersions/{vers[0]['id']}/appStoreReviewDetail")
    if st == 200 and rd.get("data"):
        a = rd["data"]["attributes"]
        contact = {k: a.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail") if a.get(k)}

detail = must("GET", f"/v1/apps/{app_id}/betaAppReviewDetail", what="Beta-Prüfungsangaben")["data"]
cur = detail.get("attributes", {})
attrs = {}
for k, v in contact.items():
    if not cur.get(k):
        attrs[k] = v
if cur.get("demoAccountRequired") is None or cur.get("demoAccountRequired"):
    attrs["demoAccountRequired"] = False
if not cur.get("notes"):
    attrs["notes"] = ("Kein Konto nötig: Auf der Startseite „Demo“ wählen – dort laufen freie Testvideos. "
                      "ImperumTV ist nur ein Player für eigene Wiedergabelisten und enthält keine Inhalte.")
if attrs:
    must("PATCH", f"/v1/betaAppReviewDetails/{detail['id']}",
         {"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": attrs}},
         what="Beta-Prüfungsangaben speichern")
merged = {**cur, **attrs}
missing = [k for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail") if not merged.get(k)]
if missing:
    fail("In App Store Connect fehlen Kontaktangaben für die Beta-Prüfung: " + ", ".join(missing) +
         " (TestFlight → Testinformationen ausfüllen, dann erneut starten)")
feedback_mail = merged.get("contactEmail")

locs = must("GET", f"/v1/apps/{app_id}/betaAppLocalizations", what="Beta-Beschreibung")["data"]
if not locs:
    must("POST", "/v1/betaAppLocalizations",
         {"data": {"type": "betaAppLocalizations",
                   "attributes": {"locale": "de-DE", "description": DESCRIPTION, "feedbackEmail": feedback_mail},
                   "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
         what="Beta-Beschreibung anlegen")
else:
    for l in locs:
        la = l["attributes"]
        upd = {}
        if not la.get("description"):
            upd["description"] = DESCRIPTION
        if not la.get("feedbackEmail"):
            upd["feedbackEmail"] = feedback_mail
        if upd:
            must("PATCH", f"/v1/betaAppLocalizations/{l['id']}",
                 {"data": {"type": "betaAppLocalizations", "id": l["id"], "attributes": upd}},
                 what="Beta-Beschreibung ergänzen")
    locale = locs[0]["attributes"].get("locale") or "de-DE"

# „Was testen?“ für diesen Build
bl = must("GET", f"/v1/builds/{build_id}/betaBuildLocalizations", what="Build-Hinweis")["data"]
if bl:
    for l in bl:
        if not l["attributes"].get("whatsNew"):
            must("PATCH", f"/v1/betaBuildLocalizations/{l['id']}",
                 {"data": {"type": "betaBuildLocalizations", "id": l["id"], "attributes": {"whatsNew": WHATS_NEW}}},
                 what="Build-Hinweis ergänzen")
else:
    for loc in sorted({(x["attributes"].get("locale") or "de-DE") for x in (locs or [])} | {"de-DE"}):
        st, data = call("POST", "/v1/betaBuildLocalizations",
                        {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": loc, "whatsNew": WHATS_NEW},
                                  "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        if st not in (200, 201, 409):
            print("Hinweis „Was testen“ (" + loc + "): HTTP", st, flush=True)

# ---------- 3. Gruppe mit öffentlichem Link ----------
groups = must("GET", f"/v1/apps/{app_id}/betaGroups?limit=50", what="Testgruppen")["data"]
grp = next((g for g in groups if g["attributes"].get("name") == GROUP and not g["attributes"].get("isInternalGroup")), None)
if not grp:
    grp = must("POST", "/v1/betaGroups",
               {"data": {"type": "betaGroups",
                         "attributes": {"name": GROUP, "publicLinkEnabled": True, "publicLinkLimitEnabled": False,
                                        "feedbackEnabled": True},
                         "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
               what="Gruppe anlegen")["data"]
elif not grp["attributes"].get("publicLinkEnabled"):
    grp = must("PATCH", f"/v1/betaGroups/{grp['id']}",
               {"data": {"type": "betaGroups", "id": grp["id"],
                         "attributes": {"publicLinkEnabled": True, "publicLinkLimitEnabled": False}}},
               what="Öffentlichen Link einschalten")["data"]
gid = grp["id"]

st, data = call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
                {"data": [{"type": "builds", "id": build_id}]})
if st not in (200, 201, 204, 409):
    errs = "; ".join(x.get("detail", "") for x in data.get("errors", []))
    fail(f"Build zur Gruppe hinzufügen → HTTP {st}: {errs}")

# ---------- 4. Zur Beta-Prüfung einreichen ----------
st, data = call("POST", "/v1/betaAppReviewSubmissions",
                {"data": {"type": "betaAppReviewSubmissions",
                          "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
if st in (200, 201):
    review = "zur Beta-Prüfung eingereicht"
elif st == 409:
    review = "war schon eingereicht oder ist schon freigegeben"
else:
    errs = "; ".join((x.get("title", "") + ": " + x.get("detail", "")) for x in data.get("errors", []))
    fail(f"Beta-Prüfung einreichen → HTTP {st}: {errs}")

st, d = call("GET", f"/v1/builds/{build_id}/buildBetaDetail")
ext = d.get("data", {}).get("attributes", {}).get("externalBuildState") if st == 200 else None

# ---------- 5. Link ----------
g = must("GET", f"/v1/betaGroups/{gid}", what="Gruppe lesen")["data"]["attributes"]
link = g.get("publicLink") or ""
note(f"Build {build_no}: {review} (Status: {ext or 'unbekannt'})")
note("Öffentlicher TestFlight-Link: " + (link or "noch keiner – erscheint nach der Freigabe"))
