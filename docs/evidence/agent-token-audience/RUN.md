# Agent-token audience, measured (2026-10-19)

This is the measurement that PR #140 lists as not proven: what an agent gets when it asks
vouchryx for a token with and without the audience, and whether the gateway and the MCP broker
admit the result. The checks are in `measure.sh`, the output is in `output-2026-10-19.txt`.

- Code measured: the head commit of PR #140 (`compose.yaml` as on `chore/pins-wave1`).
- vouchryx: `ghcr.io/taipanbox/vouchryx@sha256:4a2b6b31be44b5391974785bdfca597a88bcc5ddd834d50830bd6b9537e9ab3d` (v0.6.0).
- Gateway and broker: the tokenfuse image pinned in `compose.yaml` (v1.18.0).

## What was run

1. vouchryx with the values `install.sh` writes for `WITH_AGENT_TOKENS=1` (`agent_tokens_apply`):
   `VOUCHRYX_ALLOWED_AUDIENCES=https://stack-single.local`,
   `VOUCHRYX_AGENTS=agent://local/agents/operator|agents|local|sha256:<digest of the enrolment secret>`,
   `VOUCHRYX_ISSUER=http://vouchryx:4310`, a signing key and a demo issuer from `vouchryx-demo keygen`.
2. A scratch compose project from the branch's `compose.yaml`, with a `.env` that gives every
   `${...:?}` secret a fake value and sets the agent-token values the installer writes:
   `TOKENFUSE_AGENT_TOKENS=accept`, `TOKENFUSE_DELEGATION_ISSUER=http://vouchryx:4310`,
   `TOKENFUSE_DELEGATION_JWKS=/etc/tokenfuse/delegation/vouchryx.jwks.json` (the signing JWKS),
   `TOKENFUSE_DELEGATION_AUDIENCE=https://stack-single.local`, `TOKENFUSE_DELEGATION_URL=http://127.0.0.1:4100`,
   `MCP_BROKER_DELEGATION_AUDIENCE=https://stack-single.local`, `MCP_BROKER_DELEGATION_URL=http://127.0.0.1:4200`.
   Then `docker compose --profile typed up -d --no-deps tokenfuse-gateway tokenfuse-mcp-broker`.
3. The vouchryx container joined the project's `core` network with the alias `vouchryx`
   (`docker network connect --alias vouchryx agent-stack_core vx-agent`), because the gateway and the
   broker poll the revocation list at `http://vouchryx:4310` and their issuer is that name.
4. `ENROL_SECRET=<secret> AUDIENCE=https://stack-single.local ./measure.sh`.

## Result

| Step | Answer | Meaning |
|---|---|---|
| exchange with `resource=https://stack-single.local` | 200, DPoP token, 300 s | issued |
| exchange with no resource | 400 `invalid_target` | refused: vouchryx logs `audience_not_allowed [audience=http://vouchryx:4310]` |
| gateway, issued token | 503 `seed_pending` | admitted past the agent-token check; stops at the budget step |
| gateway, one byte of the signature flipped | 401 `agent_token_refused` | refused |
| broker `tools/list`, issued token | 200, JSON-RPC `upstream error` | admitted; the call reaches the upstream step |
| broker, flipped signature | 401 `agent_token_refused` | refused |

The no-resource refusal is the rule in `internal/config/config.go` (`AllowsAudience`) and
`internal/api/agents.go`: an exchange with no `resource` or `audience` falls back to vouchryx's
own issuer, and an allow-list that names only the https audience does not include it.

## Deviations from a live install

- `install.sh` was not run. It needs root on Debian or Ubuntu, and this check ran on a Mac. The
  values above are the ones its code writes, not a run of it.
- Only the gateway and the broker were started (`--no-deps`). typryx, tokenfuse-cloud, wardryx and
  policy-db were not running. So the broker answers its upstream error, and the gateway stops at
  `seed_pending` (the control plane is not there). Both are after the agent-token check.
- The events volume was not initialised (`init-volumes` did not run). The gateway and broker log that
  their agent-event export is off. This does not touch the admission check.
- The client keys and the identity map are fake here, so the identity check was not measured.

## Findings from the run

- A DPoP proof sent to a resource server must carry `ath`, the base64url SHA-256 of the access token
  (RFC 9449). The first gateway call sent a proof without it, and both the gateway and the broker
  refused the valid token as `agent_token_refused`. Every client sends `ath`. This is a requirement on
  the agent, not a fault in vouchryx.
- Two earlier exchanges returned `400 unauthorized_client`, which vouchryx's log does not record. Every
  exchange after them, in the debug runs and in `measure.sh`, returned the expected answer. I did not
  identify the cause, so it is open. A separate debug command of mine passed a bad secret; vouchryx logged
  that as `client_auth_failed`, which is not one of these two.

## Not in the output

No secret and no full token is written here. `dpop_exchange.py` prints the first 24 characters of a
token, and `admit.py` prints the response body only.
