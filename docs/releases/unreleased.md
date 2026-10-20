# Unreleased, after stack-single 1.3.1

Draft notes for the next release, which the supervisor names and dates when it is cut.

## Upgrade first

1. Re-run `./install.sh` on each box, as for 1.3.1. Items 2 to 4 act on that run by themselves, except where a step below says otherwise.

2. **A box installed on 1.3.1 printed its console password into its install log, so change that password.** The 1.3.1 closing report printed it. A later install does not change an existing console operator, so the old password still works until you change it. Change it, then clear the install log that holds it. From the stack directory (`/opt/agent-stack` unless you set `STACK_DIR`):

   ```sh
   cd /opt/agent-stack
   read -r -s -p 'new console password (12 characters or more): ' PW && echo
   printf '%s\n' "$PW" | sudo docker compose exec -T console /usr/local/bin/genaryx-web set-password --username ops
   unset PW
   sudo docker compose restart console
   ```

   The username is `ops` unless you set `CONSOLE_USER`. The password is read from standard input, so it is not in the process list, and it is not on the command line. The console refuses a password under 12 characters. A console that is already running keeps the old password until it restarts, which is why the last line restarts it. Then sign in with the new password. The command is the one in genaryx's `set-password` path (genaryx `v1.1.45`, the version this stack pins). It was read from that source, not run on a live box for this note.

   A box installed from this release keeps its first password in `STACK_DIR/console-password` (mode 0600), and the closing report names that file and the one command that reads it. Delete that file once you have saved the password.

3. **With `TYPED_RISK_SIGNAL=1`,** the run writes the managed rule `typed-risk-hold-when-absent` into `policy.yaml` and restarts wardryx, which reads that file at start. From then on a tool call with no risk signal is held for a person, and so is one the classifier marks `destructive`, `external_send` or `financial` at 0.8 or more. That is the rule stack-up seeds. Other classes, or other thresholds, are your own `hold_if_signal` rule (README).

4. **vouchryx signs with the key keyryx certifies, by default.** The run takes the delegation root pin from the keyryx on the box and starts vouchryx on the certified key. Verifiers take the new key from the served key set. A box that wants the file key sets `VOUCHRYX_SIGNER=file` in `.env` before the run. To move the pin to a root keyryx now serves, follow the re-pin steps in the README ("Re-pinning keyryx's delegation root, on purpose"). This launcher sets no keyryx admin key, so a root cannot be rotated from this stack yet.

5. **CostCrew's runner spends only through the gateway, under a ceiling, and only when a person starts it.** The add-on's console could never spend, and its runner (`costcrew-run`) was not wired at all. Nothing changes until you ask. Two things follow from the upgrade, and both are yours to choose. First, the run adds the crew's client key `GATEWAY_COSTCREW_KEY` to `.env` and to the identity map, bound to `agent://<domain>/costcrew/*` in unit `costcrew`. The gateway accepts it from then on, and no service presents it until the runner is started. Second, `COSTCREW_CEILING` is written to `.env`, and it is `0` unless you set it: with `0` a runner run spends nothing, and the crew's key is not kept. The key is minted only while the ceiling is above 0, and a run at 0 removes it from the gateway's keys, so no unused credential is accepted. To allow spending, set `COSTCREW_CEILING` (a decimal, such as `25.00`), run `./install.sh` again, turn cadence on at the console's `/cadence` page, and start the runner with `docker compose --profile finops --profile crew run --rm costcrew-run`. Nothing schedules it here. Its runs are recorded in the costcrew store, not on the bus, because the bus stream has one writer.

6. **wardryx 2.4.0, and the console's approver key (CLAUDE.md invariant 58).** Before you upgrade a box that sets an agent-token issuer (the default), confirm that the gateway and the MCP broker send a fresh DPoP proof with each `/v1/decide` call. wardryx 2.4.0 refuses a proof it has already seen within its window with `403 agent_token_proof_invalid`, and one agent request that causes two decisions must not reuse its proof. The installer mints the approver key on the first run, and keeps it. This release does not switch approver statements on: the pinned console image cannot print its key set yet. When a console image built after genaryx #132 is pinned, the next run writes the key set and turns the check on. From then on a console without an enrolled passkey cannot sign an approval, so its approvals are refused with `approver_statement_required`. Enrol the passkey before that console image is pinned. Rolling back to wardryx 2.3.0 ignores the two new settings.

7. **The record seal signs through keyryx (CLAUDE.md invariant 59).** A run mints the seal's credential `keyryx/record-seal.key` (mode 0400, read only by the seal) and gives keyryx its digest. The seal then signs each sealed root, and the keyryx witness attests to the records. Boxes that do not run the record plane see the credential and the digest and nothing else changes. The root pin, `TRAILRYX_KEYRYX_KID`, is not set: trailryx 1.5.0 has not released it (trailryx#112), so until it does the signer is not pinned to a root.

## Not in this release

- The root pin for the record pack's signer (`TRAILRYX_KEYRYX_KID`) waits for trailryx 1.5.0 (trailryx#112). The signer itself is on, as item 7 says.
- The console's passkey requirement is already on in the compose file. The first-login enrolment that makes it safe to leave on waits for genaryx.
- The console image pin stays at v1.1.48. A genaryx console release built after #132 (approver statements, `approver-jwks`) is what item 6 waits for.

## NOT proven

- **A keyryx root cannot be rotated from this stack.** The launcher never sets `KEYRYX_ADMIN_KEYS`, so keyryx's rotate and revoke routes refuse every call on a box it installed. A rotation needs that variable, which is not wired yet, and the re-pin steps in the README cover only a root that changed by other means.
- **The record seal does not read the witness's attestations.** keyryx v0.1.1 writes each one mode 0600 under the witness's uid, and the seal (uid 10001) cannot read it. `TRAILRYX_WITNESS_ATTESTATIONS` stays unset (TODO(keyryx-attest-mode)) until a keyryx release writes them group-readable.
- **The record seal's root pin is not set.** `TRAILRYX_KEYRYX_KID` waits for trailryx 1.5.0 (trailryx#112).
- **Nothing signed by the record seal has been verified live.** The seal's keyryx path, its bearer credential over HTTP, and the witness's attestations were read from source, not run.
- **Approver statements are not live.** They stay off until a console image with `approver-jwks` is pinned.
- **Single-use DPoP proofs are not checked against the gateway and the broker.** The Upgrade note asks you to confirm they send a fresh proof per decision before you upgrade a box with an agent-token issuer.
- **The CostCrew runner has not spent money.** Its wiring was read and gated, not run against a model provider.
- **The console password change procedure was not run.** It was read from genaryx's source at the release that v1.1.45 pins.
