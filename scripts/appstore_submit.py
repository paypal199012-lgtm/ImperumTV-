#!/usr/bin/env python3
"""
ImperumTV (iPhone): hochgeladenen Build als neue App-Store-Version zur Prüfung einreichen.

  1. warten, bis der Build (CFBundleVersion = BUILD_NO) fertig verarbeitet ist
  2. App-Store-Version VERSION anlegen (oder die offene nehmen), „Neu in dieser Version“ eintragen, Build zuordnen
  3. zur Prüfung bei Apple einreichen

Schlüssel nur aus GitHub-Secrets, werden nie ausgegeben.
"""
import json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com"
BUNDLE = os.environ.get("BUNDLE_ID") or "tv.imperum.app"
VERSION = os.environ["VERSION"]
BUILD_NO = os.environ["BUILD_NO"]
WHATS_NEW = os.environ.get("WHATS_NEW") or "Fehlerbehebungen und Verbesserungen."
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
    d = must("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD_NO}&filter[preReleaseVersion.platform]=IOS"
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
vers = must("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10", what="Versionen")["data"]
ver = next((v for v in vers if v["attributes"].get("versionString") == VERSION), None)
if ver and ver["attributes"].get("appStoreState") not in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
    fail(f"Version {VERSION} ist schon {ver['attributes'].get('appStoreState')} – bitte VERSION erhöhen")
if not ver:
    ver = must("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
              "attributes": {"platform": "IOS", "versionString": VERSION},
              "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}, what="Version anlegen")["data"]
ver_id = ver["id"]

for loc in must("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations", what="Texte")["data"]:
    must("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
         {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": WHATS_NEW}}},
         what="„Neu in dieser Version“ (" + loc["attributes"].get("locale", "?") + ")")

must("PATCH", f"/v1/appStoreVersions/{ver_id}/relationships/build", {"data": {"type": "builds", "id": build_id}}, what="Build zuordnen")
note(f"Version {VERSION} mit Build {BUILD_NO} vorbereitet")

# 3. Einreichen (Review Submission)
subs = must("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW", what="Einreichungen")["data"]
sub = subs[0] if subs else must("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
         "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}, what="Einreichung anlegen")["data"]
st, d = call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems",
             "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                               "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
if st not in (200, 201, 409):
    errs = "; ".join((x.get("title", "") + ": " + x.get("detail", "")) for x in d.get("errors", []))
    fail(f"Version zur Einreichung hinzufügen → HTTP {st}: {errs}")
must("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}},
     what="Zur Prüfung einreichen")
note(f"iPhone-Version {VERSION} (Build {BUILD_NO}) ist zur Prüfung bei Apple eingereicht")
