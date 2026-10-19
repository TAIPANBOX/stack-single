"""Exchange an agent's enrolment secret at vouchryx's token endpoint, with a DPoP proof.

stdlib + openssl only. Prints the HTTP status and the JSON body of each exchange.
usage: dpop_exchange.py BASE_URL CLIENT_ID SECRET HTU [resource]
"""
import base64, hashlib, json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request, uuid


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der, n=32):
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }
    assert der[0] == 0x30
    i = 2
    if der[1] & 0x80:
        i = 2 + (der[1] & 0x7F)
    out = []
    for _ in range(2):
        assert der[i] == 0x02
        ln = der[i + 1]
        val = der[i + 2:i + 2 + ln]
        i += 2 + ln
        val = val.lstrip(b"\x00")
        out.append(val.rjust(n, b"\x00"))
    return out[0] + out[1]


def make_proof(htm, htu, workdir, key=None, ath=None):
    key = key or os.path.join(workdir, "dpop.pem")
    if not os.path.exists(key):
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key], check=True)
    pub = subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    point = pub[-65:]
    assert point[0] == 4
    jwk = {"kty": "EC", "crv": "P-256", "x": b64u(point[1:33]), "y": b64u(point[33:65])}
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": jwk}
    payload = {"jti": str(uuid.uuid4()), "htm": htm, "htu": htu, "iat": int(time.time())}
    if ath is not None:
        payload["ath"] = ath
    signing_input = (b64u(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     b64u(json.dumps(payload, separators=(",", ":")).encode())).encode()
    sig_path = os.path.join(workdir, "sig.der")
    with open(os.path.join(workdir, "in.bin"), "wb") as f:
        f.write(signing_input)
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", sig_path,
                    os.path.join(workdir, "in.bin")], check=True)
    raw = der_to_raw(open(sig_path, "rb").read())
    return signing_input.decode() + "." + b64u(raw)


def exchange(base, client_id, secret, htu, resource, workdir, key=None):
    body = {"grant_type": "client_credentials"}
    if resource is not None:
        body["resource"] = resource
    data = urllib.parse.urlencode(body).encode()
    basic = base64.b64encode(
        (urllib.parse.quote(client_id, safe="") + ":" + urllib.parse.quote(secret, safe="")).encode()).decode()
    proof = make_proof("POST", htu, workdir, key)
    req = urllib.request.Request(base + "/v1/token", data=data, method="POST", headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": "Basic " + basic,
        "DPoP": proof,
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


if __name__ == "__main__":
    # usage: dpop_exchange.py BASE CLIENT_ID SECRET HTU RESOURCE|- KEY_PEM [TOKEN_OUT]
    base, client_id, secret, htu, resource, key = sys.argv[1:7]
    resource = None if resource == "-" else resource
    wd = tempfile.mkdtemp(prefix="dpop-")
    status, body = exchange(base, client_id, secret, htu, resource, wd, key)
    if "access_token" in body and len(sys.argv) > 7:
        open(sys.argv[7], "w").write(body["access_token"])
    shown = dict(body)
    if "access_token" in shown:
        tok = shown["access_token"]
        shown["access_token"] = tok[:24] + "...(" + str(len(tok)) + " chars)"
    print(json.dumps({"status": status, "body": shown}, indent=2))
