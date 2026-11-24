#!/usr/bin/env python3
"""
App Store Connect: Person einladen (Rolle Marketing, nur ImperumTV) und danach in die interne TestFlight-Gruppe setzen.
Die Angaben zur Person kommen verschlüsselt (das Repository ist öffentlich) und werden nie ausgegeben.
Ohne Daten gibt das Skript nur den öffentlichen Schlüssel zum Verschlüsseln aus.
"""
import base64, json, os, sys, time, urllib.error, urllib.request
import jwt
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

API = "https://api.appstoreconnect.apple.com"
BUNDLE = os.environ.get("BUNDLE_ID") or "tv.imperum.app"
P8 = os.environ["ASC_KEY_P8"]
priv = serialization.load_pem_private_key(P8.encode(), password=None)
pub = priv.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
print("::notice::Öffentlicher Schlüssel: " + base64.b64encode(pub).decode(), flush=True)

DATA = (os.environ.get("DATA") or "").strip()
STEP = os.environ.get("STEP") or "einladen"
if not DATA and STEP not in ("build", "build-tv"):
    sys.exit(0)

EMAIL = FIRST = LAST = None
if DATA:
    raw = base64.b64decode(DATA)
    eph = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw[:65])
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"imperumtv-invite").derive(priv.exchange(ec.ECDH(), eph))
    info = json.loads(AESGCM(key).decrypt(raw[65:77], raw[77:], None))
    print("::add-mask::" + info["email"], flush=True)
    EMAIL, FIRST, LAST = info["email"], info["first"], info["last"]


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      P8, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + token()); req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            b = r.read(); return r.status, (json.loads(b) if b else {})
    except urllib.error.HTTPError as e:
        b = e.read()
        try: return e.code, json.loads(b)
        except Exception: return e.code, {}


def errs(d):
    return "; ".join((x.get("title", "") + ": " + x.get("detail", "")) for x in d.get("errors", [])) or "?"


st, d = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE}")
app_id = d["data"][0]["id"]

if STEP == "entfernen" and EMAIL:
    # alles zu dieser Adresse entfernen: offene Einladung, Team-Zugang, TestFlight-Tester
    from urllib.parse import quote
    st, d = call("GET", "/v1/userInvitations?filter[email]=" + quote(EMAIL) + "&limit=5")
    for inv in d.get("data", []):
        st2, _ = call("DELETE", "/v1/userInvitations/" + inv["id"]); print("::notice::Einladung zurückgezogen: HTTP " + str(st2), flush=True)
    st, d = call("GET", "/v1/users?filter[username]=" + quote(EMAIL) + "&limit=5")
    for u in d.get("data", []):
        st2, _ = call("DELETE", "/v1/users/" + u["id"]); print("::notice::Team-Zugang entfernt: HTTP " + str(st2), flush=True)
    st, d = call("GET", "/v1/betaTesters?filter[email]=" + quote(EMAIL) + "&limit=5")
    for t in d.get("data", []):
        st2, d2 = call("DELETE", "/v1/betaTesters/" + t["id"]); print("::notice::TestFlight-Tester entfernt: HTTP " + str(st2) + ("" if st2 in (200, 204) else " " + errs(d2)), flush=True)
    print("::notice::Fertig", flush=True)

if STEP == "zurueck" and EMAIL:
    from urllib.parse import quote
    st, d = call("GET", "/v1/userInvitations?filter[email]=" + quote(EMAIL) + "&limit=5")
    for inv in d.get("data", []):
        st2, _ = call("DELETE", "/v1/userInvitations/" + inv["id"])
        print("::notice::Einladung zurückgezogen: HTTP " + str(st2), flush=True)
    if not d.get("data"):
        print("::notice::Keine offene Einladung gefunden", flush=True)

if STEP == "neu" and EMAIL:
    from urllib.parse import quote
    st, d = call("GET", "/v1/userInvitations?filter[email]=" + quote(EMAIL) + "&limit=5")
    for inv in d.get("data", []):
        st2, _ = call("DELETE", "/v1/userInvitations/" + inv["id"])
        print("::notice::Alte Einladung zurückgezogen: HTTP " + str(st2), flush=True)
    STEP = "einladen"

if STEP == "einladen":
    st, d = call("POST", "/v1/userInvitations", {"data": {"type": "userInvitations",
        "attributes": {"email": EMAIL, "firstName": FIRST, "lastName": LAST, "roles": ["MARKETING"],
                       "allAppsVisible": False, "provisioningAllowed": False},
        "relationships": {"visibleApps": {"data": [{"type": "apps", "id": app_id}]}}}})
    if st in (200, 201):
        print("::notice::Einladung verschickt (Rolle Marketing, nur ImperumTV). Die Person muss sie per E-Mail annehmen.", flush=True)
    else:
        print(f"::error::Einladen → HTTP {st}: {errs(d)}", flush=True); sys.exit(1)

if STEP == "testgruppe":
    st, d = call("GET", f"/v1/apps/{app_id}/betaGroups?limit=50")
    groups = [g for g in d.get("data", []) if g["attributes"].get("isInternalGroup")]
    if not groups:
        print("::error::Keine interne TestFlight-Gruppe gefunden", flush=True); sys.exit(1)
    g = groups[0]
    st, d = call("POST", "/v1/betaTesters", {"data": {"type": "betaTesters",
        "attributes": {"email": EMAIL, "firstName": FIRST, "lastName": LAST},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}}}})
    if st in (200, 201):
        print("::notice::In die interne TestFlight-Gruppe „" + g["attributes"].get("name", "?") + "“ aufgenommen.", flush=True)
    else:
        print(f"::error::Testgruppe → HTTP {st}: {errs(d)}", flush=True); sys.exit(1)

if STEP in ("build", "build-tv"):
    # neuesten fertigen iPhone- bzw. Apple-TV-Build in die interne Gruppe legen
    plat = "TV_OS" if STEP == "build-tv" else "IOS"
    st, d = call("GET", f"/v1/builds?filter[app]={app_id}&filter[preReleaseVersion.platform]={plat}&sort=-uploadedDate&limit=3&fields[builds]=version,processingState")
    b = next((x for x in d.get("data", []) if x["attributes"].get("processingState") == "VALID"), None)
    st, d = call("GET", f"/v1/apps/{app_id}/betaGroups?limit=50")
    for g in [g for g in d.get("data", []) if g["attributes"].get("isInternalGroup")]:
        st2, d2 = call("POST", f"/v1/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": b["id"]}]})
        print("::notice::Build " + b["attributes"]["version"] + " → interne Gruppe „" + g["attributes"].get("name", "?") + "“: HTTP " + str(st2) + ("" if st2 in (200, 201, 204, 409) else " " + errs(d2)), flush=True)

if STEP == "pruefen" and EMAIL:
    from urllib.parse import quote
    st, d = call("GET", "/v1/users?filter[username]=" + quote(EMAIL) + "&limit=5")
    print("::notice::Benutzer im Team: HTTP " + str(st) + ", gefunden: " + str(len(d.get("data", []))) + (" · Rollen: " + ",".join(d["data"][0]["attributes"].get("roles", [])) if d.get("data") else ""), flush=True)
    st, d = call("GET", "/v1/userInvitations?filter[email]=" + quote(EMAIL) + "&limit=5")
    print("::notice::Offene Einladungen: HTTP " + str(st) + ", " + str(len(d.get("data", []))), flush=True)
    st, d = call("GET", "/v1/betaTesters?filter[email]=" + quote(EMAIL) + "&include=betaGroups&limit=5")
    for t in d.get("data", []):
        gs = [x["attributes"].get("name") for x in d.get("included", []) if x["type"] == "betaGroups"]
        print("::notice::Tester gefunden: Einladungsart " + str(t["attributes"].get("inviteType")) + ", Status " + str(t["attributes"].get("state")) + ", Gruppen: " + ",".join(map(str, gs)), flush=True)
    if not d.get("data"):
        print("::notice::Kein TestFlight-Tester mit dieser Adresse (HTTP " + str(st) + ")", flush=True)
