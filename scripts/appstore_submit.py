#!/usr/bin/env python3
"""
ImperumTV (iPhone oder Apple TV): hochgeladenen Build als neue App-Store-Version zur Prüfung einreichen.
PLATFORM=IOS (Standard) oder TV_OS.

  1. warten, bis der Build (CFBundleVersion = BUILD_NO) fertig verarbeitet ist
  2. App-Store-Version VERSION anlegen (oder die offene nehmen), „Neu in dieser Version“ eintragen, Build zuordnen
  3. zur Prüfung bei Apple einreichen

Schlüssel nur aus GitHub-Secrets, werden nie ausgegeben.
"""
import glob, hashlib, json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com"
BUNDLE = os.environ.get("BUNDLE_ID") or "tv.imperum.app"
VERSION = os.environ["VERSION"]
BUILD_NO = os.environ["BUILD_NO"]
WHATS_NEW = os.environ.get("WHATS_NEW") or "Fehlerbehebungen und Verbesserungen."
PLATFORM = os.environ.get("PLATFORM") or "IOS"
DEVICE = "Apple-TV" if PLATFORM == "TV_OS" else "iPhone"
# Erklärung für die Prüfer (App Review → Notizen), wird bei jeder Einreichung eingetragen
REVIEW_NOTES = """ImperumTV is a free media player. It contains no content and sells nothing.

- No In-App Purchases, no subscriptions, no paid features, no accounts. Everything in the app is free for all users.
- The app only plays playlists (M3U or Xtream Codes) that users already have. We do not sell, provide, recommend or link to any playlists, content or content providers, and have no affiliation with any provider.
- If the user's own playlist server reports an expiry date, the app only shows it as information ("valid until"). It is not an ImperumTV subscription and nothing in the app depends on it.
- Adding a playlist: the user scans the QR code in the app and enters the playlist address on our website. This is free for iPhone and Apple TV, with no payment and no account.

How to review: no account needed. Choose "Demo" on the start screen to play free test videos."""
_t = {"tok": None, "at": 0}


def note(m): print("::notice::" + m, flush=True)


def fail(m):
    print("::error::" + m, flush=True)
    sys.exit(1)


def token():
    if not _t["tok"] or time.time() - _t["at"] > 600:
        now = int(time.time())
        _t["tok"] = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                               os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
        _t["at"] = time.time()
    return _t["tok"]


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")[:400]}


def must(method, path, body=None, what=""):
    st, d = call(method, path, body)
    if st not in (200, 201, 204):
        errs = "; ".join((x.get("title", "") + ": " + x.get("detail", "")) for x in d.get("errors", [])) or str(d)[:400]
        fail(f"{what or path} → HTTP {st}: {errs}")
    return d


app = must("GET", f"/v1/apps?filter[bundleId]={BUNDLE}", what="App")["data"]
if not app:
    fail("App nicht gefunden")
app_id = app[0]["id"]

# 1. Build abwarten
build = None
for _ in range(60):
    d = must("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD_NO}&filter[preReleaseVersion.platform]={PLATFORM}"
                    f"&fields[builds]=version,processingState", what="Build")["data"]
    if d and d[0]["attributes"].get("processingState") == "VALID":
        build = d[0]
        break
    if d and d[0]["attributes"].get("processingState") in ("FAILED", "INVALID"):
        fail("Build " + BUILD_NO + " ist " + d[0]["attributes"]["processingState"])
    print("Build", BUILD_NO, "wird noch verarbeitet …", flush=True)
    time.sleep(30)
if not build:
    fail("Build " + BUILD_NO + " nach 30 Minuten noch nicht fertig – später „Einreichen“ erneut starten")
build_id = build["id"]
note(f"Build {BUILD_NO} ist fertig verarbeitet")

# 2. Version anlegen oder offene nehmen
vers = must("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]={PLATFORM}&limit=10", what="Versionen")["data"]
ver = next((v for v in vers if v["attributes"].get("versionString") == VERSION), None)
# Austauschen: wartet dieselbe Version noch auf die Prüfung, Einreichung zurückziehen und mit dem neuen Build neu einreichen
if ver and ver["attributes"].get("appStoreState") == "WAITING_FOR_REVIEW":
    waiting = must("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]={PLATFORM}&filter[state]=WAITING_FOR_REVIEW",
                   what="Wartende Einreichung")["data"]
    for w in waiting:
        must("PATCH", f"/v1/reviewSubmissions/{w['id']}", {"data": {"type": "reviewSubmissions", "id": w["id"], "attributes": {"canceled": True}}},
             what="Wartende Einreichung zurückziehen")
    note(f"Version {VERSION} wartete noch auf die Prüfung – zurückgezogen, wird mit Build {BUILD_NO} neu eingereicht")
    for _ in range(40):
        time.sleep(15)
        ver = must("GET", f"/v1/appStoreVersions/{ver['id']}", what="Version")["data"]
        if ver["attributes"].get("appStoreState") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"):
            break
        print("Zurückziehen läuft …", ver["attributes"].get("appStoreState"), flush=True)
if ver and ver["attributes"].get("appStoreState") not in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
    fail(f"Version {VERSION} ist schon {ver['attributes'].get('appStoreState')} – bitte VERSION erhöhen")
if not ver:
    ver = must("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
              "attributes": {"platform": PLATFORM, "versionString": VERSION},
              "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}, what="Version anlegen")["data"]
ver_id = ver["id"]

for loc in must("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations", what="Texte")["data"]:
    must("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
         {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": WHATS_NEW}}},
         what="„Neu in dieser Version“ (" + loc["attributes"].get("locale", "?") + ")")

# iPad-Bildschirmfotos (13 Zoll, 2732×2048) für jede Sprache, falls noch keine da sind
IPAD_SHOTS = sorted(glob.glob(os.path.join(os.environ.get("IPAD_SHOTS") or "store/ipad", "*.png")))


def put_bytes(url, data, headers):
    req = urllib.request.Request(url, method="PUT", data=data)
    for h in headers or []:
        req.add_header(h["name"], h["value"])
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status


def ipad_shots(loc_id, locale):
    sets = must("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets", what="Bildschirmfoto-Sätze")["data"]
    sset = next((x for x in sets if x["attributes"].get("screenshotDisplayType") == "APP_IPAD_PRO_3GEN_129"), None)
    if not sset:
        sset = must("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": "APP_IPAD_PRO_3GEN_129"},
                    "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}},
                    what="iPad-Satz anlegen")["data"]
    have = must("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots", what="iPad-Fotos")["data"]
    if have:
        note(f"iPad-Bildschirmfotos ({locale}): schon {len(have)} vorhanden")
        return
    ids = []
    for f in IPAD_SHOTS:
        data = open(f, "rb").read()
        shot = must("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
                    "attributes": {"fileName": os.path.basename(f), "fileSize": len(data)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["id"]}}}}},
                    what="iPad-Foto anmelden")["data"]
        for op in shot["attributes"].get("uploadOperations") or []:
            off, ln = op["offset"], op["length"]
            put_bytes(op["url"], data[off:off + ln], op.get("requestHeaders"))
        must("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
             "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}, what="iPad-Foto abschließen")
        ids.append(shot["id"])
    # warten, bis Apple die Fotos verarbeitet hat
    for _ in range(40):
        states = [must("GET", f"/v1/appScreenshots/{i}", what="iPad-Foto")["data"]["attributes"].get("assetDeliveryState", {}).get("state") for i in ids]
        if all(s == "COMPLETE" for s in states):
            break
        if any(s == "FAILED" for s in states):
            fail(f"iPad-Bildschirmfoto ({locale}) von Apple abgelehnt")
        time.sleep(6)
    note(f"iPad-Bildschirmfotos ({locale}): {len(ids)} hochgeladen")


if PLATFORM == "IOS" and IPAD_SHOTS:
    for loc in must("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations", what="Texte")["data"]:
        ipad_shots(loc["id"], loc["attributes"].get("locale", "?"))

must("PATCH", f"/v1/appStoreVersions/{ver_id}/relationships/build", {"data": {"type": "builds", "id": build_id}}, what="Build zuordnen")
# Erklärung für die Prüfer eintragen (Kontaktdaten bleiben wie in App Store Connect)
st, rd = call("GET", f"/v1/appStoreVersions/{ver_id}/appStoreReviewDetail")
rd_id = (rd.get("data") or {}).get("id") if st == 200 else None
if rd_id:
    st, d = call("PATCH", f"/v1/appStoreReviewDetails/{rd_id}", {"data": {"type": "appStoreReviewDetails", "id": rd_id,
                 "attributes": {"notes": REVIEW_NOTES, "demoAccountRequired": False}}})
else:
    # Neue Version ohne Prüfungsangaben: Kontaktdaten von einer früheren Version übernehmen
    contact = {}
    for v in vers:
        s2, r2 = call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail")
        if s2 == 200 and r2.get("data"):
            a = r2["data"]["attributes"]
            contact = {k: a.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail") if a.get(k)}
            if contact:
                break
    st, d = call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails",
                 "attributes": {**contact, "notes": REVIEW_NOTES, "demoAccountRequired": False},
                 "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
if st in (200, 201):
    note("Erklärung für die Prüfer eingetragen")
else:
    print("Hinweis: Erklärung für die Prüfer nicht gespeichert (HTTP", st, ") – bitte in App Store Connect unter „App-Prüfung → Notizen“ eintragen", flush=True)
note(f"Version {VERSION} mit Build {BUILD_NO} vorbereitet")

# 3. Einreichen (Review Submission)
subs = must("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]={PLATFORM}&filter[state]=READY_FOR_REVIEW", what="Einreichungen")["data"]
sub = subs[0] if subs else must("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
         "attributes": {"platform": PLATFORM}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}, what="Einreichung anlegen")["data"]
st, d = call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems",
             "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                               "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
if st not in (200, 201, 409):
    errs = "; ".join((x.get("title", "") + ": " + x.get("detail", "")) for x in d.get("errors", []))
    fail(f"Version zur Einreichung hinzufügen → HTTP {st}: {errs}")
must("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}},
     what="Zur Prüfung einreichen")
note(f"{DEVICE}-Version {VERSION} (Build {BUILD_NO}) ist zur Prüfung bei Apple eingereicht")
