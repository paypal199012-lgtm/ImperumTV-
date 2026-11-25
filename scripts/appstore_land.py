"""App in weiteren Ländern freischalten (App Store Connect → Preise und Verfügbarkeit). LAENDER = z. B. "TUR" oder "TUR,AUT"."""
import os, json, time, urllib.request, jwt

def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})

def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            t = r.read()
            return r.status, (json.loads(t) if t else {})
    except urllib.error.HTTPError as e:
        t = e.read()
        try: return e.code, json.loads(t)
        except Exception: return e.code, {"raw": t.decode(errors="replace")[:500]}

want = [x.strip().upper() for x in os.environ.get("LAENDER", "").split(",") if x.strip()]
bundle = os.environ.get("BUNDLE_ID") or "tv.imperum.app"
st, d = call("GET", "/v1/apps?filter[bundleId]=" + bundle)
app = d["data"][0]["id"]
st, d = call("GET", f"/v1/apps/{app}/appAvailabilityV2")
avid = d["data"]["id"]
url, found = f"/v2/appAvailabilities/{avid}/territoryAvailabilities?limit=200&include=territory", {}
while url:
    st, d = call("GET", url)
    for t in d.get("data", []):
        tid = (t.get("relationships", {}).get("territory", {}).get("data") or {}).get("id")
        found[tid] = t
    nxt = d.get("links", {}).get("next")
    url = nxt.replace("https://api.appstoreconnect.apple.com", "") if nxt else None
ok = True
for land in want:
    t = found.get(land)
    if not t:
        print(f"::error::{land}: Land nicht gefunden"); ok = False; continue
    if t["attributes"].get("available"):
        print(f"::notice::{land}: war schon freigegeben"); continue
    st, d = call("PATCH", f"/v1/territoryAvailabilities/{t['id']}", {"data": {"type": "territoryAvailabilities", "id": t["id"],
                                                                     "attributes": {"available": True}}})
    if st in (200, 201):
        print(f"::notice::{land}: freigegeben – Status jetzt {d.get('data', {}).get('attributes', {}).get('contentStatuses')}")
    else:
        print(f"::error::{land}: HTTP {st} {json.dumps(d)[:400]}"); ok = False
raise SystemExit(0 if ok else 1)
