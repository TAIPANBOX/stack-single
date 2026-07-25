# The agent stack on one machine

One command puts the whole governed stack on a box you own, ready for agents
that live somewhere else entirely.

```bash
curl -fsSL https://raw.githubusercontent.com/TAIPANBOX/stack-single/main/install.sh | bash
```

It comes up closed. The gateway is published to the host's **loopback**, so a
box that just ran an install script does not acquire an internet-facing
enforcement plane because nobody typed anything. Opening it to the agents you
actually have is one word:

```bash
GATEWAY_BIND=0.0.0.0 ./install.sh
```

Then point an agent at the gateway. Wherever that agent runs, in EKS, in a CI
job, on a laptop, its calls are metered, budgeted and policy-checked:

```bash
ANTHROPIC_BASE_URL=http://<your box>:4100
```

On a box that is already installed, edit `GATEWAY_BIND` in
`/opt/agent-stack/.env` and `docker compose up -d`. Re-running the installer
will NOT widen it: `.env` is left alone once it exists, which is the same
property that stops a re-run rotating your credentials.

## This is not the sandbox

[`stack-up`](https://github.com/TAIPANBOX/stack-up) is the local try: it binds
`127.0.0.1` on purpose, needs Rust, Go and Node on your machine, and stops when
you press Ctrl-C. It says as much about itself, and it is right to.

This is the other thing. The differences are the whole point:

| | `stack-up` | here |
|---|---|---|
| Reachable by an agent elsewhere | no, and it cannot be | yes, one variable away |
| Toolchains on your host | Rust, Go, Node, Python | docker and git |
| Survives a reboot | no | yes |
| Console sign-in | no console at all | generated, shown once |
| Credentials | a dev key | unique per box, 0600, never printed twice |

## Reaching the console: this box issues your device its own tunnel

The console is on loopback, so it is reached over a tunnel rather than exposed.
This box runs the WireGuard side itself: sign in, open Remote, and it mints
your laptop or phone a peer config as a QR. Scan, connect, and the console
answers at `http://10.9.0.1:7420` and nowhere else.

Issuing a device and revoking one both require a passkey, the same ceremony a
kill does. A peer config is a road into the control plane, so a stolen console
session must not be able to mint one quietly. Enrol a passkey on first sign-in.

SSH is still how you get in before the first device exists:

```bash
ssh -L 17420:127.0.0.1:7420 root@<your box>
```

Two details worth knowing rather than discovering:

- `51820/udp` is published, and it is the one port here that has to be. Unlike
  an HTTP plane, WireGuard answers nothing at all without a valid key: no
  banner, no handshake, nothing for a scanner to find.
- The tunnel runs in its own `wg` container because it needs `NET_ADMIN` and a
  tun device. The console holds neither: it manages peers through a
  group-readable UAPI socket on a shared volume. That split is checked by the
  installer from the console's side, because a tunnel that is up while the
  console cannot reach its socket looks perfectly healthy from outside.

## What comes up

Six containers on one Docker network, plus a one-shot `init-volumes` that
exits, wired exactly as the Kubernetes deployment wires them, because service
names resolve the same way in both:

| Service | Port | Published to a host port |
|---|---|---|
| `tokenfuse-gateway` | 4100 | **yes**, `GATEWAY_BIND` decides where: loopback by default |
| `tokenfuse-cloud` | 8080 | no |
| `wardryx` | 8090 | no |
| `idryx` | 8081 | no |
| `policy-db` (postgres) | 5432 | no |
| `console` | 7420 | loopback only |

"Not published" is not a firewall rule that might be misread: those services
have no host port at all, so nothing outside this machine can address them.
The console is on loopback because it arrives over your own tunnel:

```bash
ssh -L 17420:127.0.0.1:7420 root@<your box>
open http://localhost:17420
```

## What the installer will not do quietly

It verifies itself and tells you what it found. Three of its checks have to
FAIL to pass: the money plane, the policy plane and the store must not be
reachable from the host. Three more test the CREDENTIAL rather than the port,
because a plane with a malformed key spec starts cleanly, stays reachable and
authenticates nobody: the admin key must get 200, an unknown key 401, and the
gateway's own key 403 when it tries to read policy. And one reads back the
rule Docker actually wrote for port 4100, rather than trusting the variable
that was supposed to produce it. A green install with an open plane is the outcome
worth designing against.

If the console source is not present it says so and installs the governed
stack without it, which is a real deployment: the planes enforce with or
without a UI in front of them.

## The console is the one closed piece

Everything else here is Apache-2.0 and public. The Genaryx console is the paid,
closed part of the product, so the installer builds it only if its source is
available to you: either place it at `src/genaryx-a360`, or pass
`CONSOLE_TOKEN=<a GitHub token with access>`. Placing the source is preferred,
because it keeps a credential off the server entirely.

## Traps, already fixed here

The Kubernetes sibling of this repo,
[`stack-k8s`](https://github.com/TAIPANBOX/stack-k8s), keeps a `GOTCHAS.md`
with every trap both deployments hit. These are the ones a first install would
have walked straight into, closed here rather than left for you:

- Both planes take a bearer-key spec of the form `key:org[:role]`, and an entry
  without the `:org` half parses to **zero** valid keys. The plane then starts
  cleanly, stays reachable, and authenticates nobody. Every health check passes
  while the money plane is deaf.
- The client side of each plane takes the bare key, not the spec, and the
  gateway's key on the policy plane is a `viewer` on purpose: `/v1/decide`
  needs no more, and an enforcement point that can rewrite the policy it
  enforces is not one.
- Kubernetes has `fsGroup` for volume ownership and Compose has nothing. A
  fresh named volume is `root:root`, so the policy plane cannot write its own
  event file and the gateway drops every trace behind a single WARN. A one-shot
  init service does what `fsGroup` would.
- The identity plane loads the gateway's event log at startup and treats an
  absent file as fatal, which on a box that has served no traffic it always is.
- The money plane binds loopback by default, which inside a container means
  unreachable; the distro's `docker.io` package ships without buildx; and the
  Go builder image is older than some of the repos it compiles.

## Licence

Apache 2.0. See [LICENSE](LICENSE).
