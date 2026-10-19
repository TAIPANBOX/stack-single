"""Send one request with an agent token bound to a DPoP key. Prints status and body.

usage: admit.py URL METHOD TOKEN_FILE|- KEY_PEM [JSON_BODY]
"""
import json, sys, tempfile, urllib.request, urllib.error
sys.path.insert(0, ".")
import dpop_exchange as d

url, method, token_src, key = sys.argv[1:5]
body = sys.argv[5].encode() if len(sys.argv) > 5 else None
token = "" if token_src == "-" else open(token_src).read().strip()
if token_src.endswith(".tampered"):
    pass
htu = url.split("?")[0]
headers = {"Content-Type": "application/json"}
if token:
    import base64, hashlib
    ath = base64.urlsafe_b64encode(hashlib.sha256(token.encode()).digest()).rstrip(b"=").decode()
    proof = d.make_proof(method, htu, tempfile.mkdtemp(prefix="adm-"), key, ath)
    headers["Authorization"] = "DPoP " + token
    headers["DPoP"] = proof
    import os
    # XHDR names one extra header per line ("Name: value"), so a call can carry several.
    for line in os.environ.get("XHDR", "").split("\n"):
        if line.strip():
            k, v = line.split(":", 1)
            headers[k.strip()] = v.strip()
req = urllib.request.Request(url, data=body, method=method, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        status, text = r.status, r.read().decode(errors="replace")
except urllib.error.HTTPError as e:
    status, text = e.code, e.read().decode(errors="replace")
print(json.dumps({"status": status, "body": text}))
