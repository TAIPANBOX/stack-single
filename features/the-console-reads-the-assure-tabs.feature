# @claude 2026-11-25: the console moves to genaryx's own release image, whose
# Notifications, Keys and Record tabs read what heraldyx, Keyryx custody and the
# record seal already keep on this box. CLAUDE.md invariant 87. Scenarios are
# bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the console reads its three Assure tabs from the planes, read only

  Each tab says "not configured" without its setting, so a wrong path is a quiet
  empty tab. The gate holds each setting to the path the plane itself uses.

  Scenario: the console is not genaryx's release
    Given the tabs exist from genaryx v0.1.0, published as ghcr.io/taipanbox/genaryx
    When the console or a routine that runs its image names another reference
    Then the gate fails
    # -> gates-have-teeth.sh "console-assure: the console goes back to genaryx-console"
    # -> gates-have-teeth.sh "console-assure: a routine runs another console image"

  Scenario: Notifications reads a file heraldyx does not write
    Given heraldyx journals beside its state file, on its own volume
    When the console's path drifts, or the volume is not mounted, or is mounted writable
    Then the gate fails
    # -> gates-have-teeth.sh "console-assure: the journal path drifts from heraldyx's"
    # -> gates-have-teeth.sh "console-assure: heraldyx's volume is not mounted"
    # -> gates-have-teeth.sh "console-assure: heraldyx's journal is mounted writable"

  Scenario: Keys reaches nothing
    Given custody answers on its service name and port, and the witness has no network
    When the console names another port, or a witness that cannot answer
    Then the gate fails
    # -> gates-have-teeth.sh "console-assure: the Keys tab names the wrong port"
    # -> gates-have-teeth.sh "console-assure: the console names a witness that has no network"

  Scenario: Record reads another directory, or could change it
    Given the record seal writes the directory it passes as --data, and reads the witness's attestations
    When the console reads another directory, mounts the record writable, or lacks the attestations
    Then the gate fails
    # -> gates-have-teeth.sh "console-assure: the record is read from the wrong directory"
    # -> gates-have-teeth.sh "console-assure: the record is mounted writable"
    # -> gates-have-teeth.sh "console-assure: the attestations are not mounted"

  Scenario: the installer asks the wrong image for the console's keys
    Given compose lists the images of every service the console depends on beside the console's own
    When the approver key set or the preview key is asked of the first image in that list
    Then the gates fail, because the image that answers is not the console
    # -> gates-have-teeth.sh "console-image: the approver key set is asked of the first image compose lists"
    # -> gates-have-teeth.sh "console-image: the preview key is asked of the first image compose lists"

  Scenario: there is nothing to judge, or nothing wrong
    Given the gate compares the console with the seal's own command
    When the seal names no data directory, it says it measured nothing; when only a comment changes, it passes
    Then neither verdict is given on nothing
    # -> gates-have-teeth.sh "console-assure: no record seal to compare with (measured nothing)"
    # -> gates-have-teeth.sh "console-assure: the Keys comment is reworded (must pass)"
