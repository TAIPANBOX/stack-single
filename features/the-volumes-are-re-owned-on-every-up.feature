# @decided 2026-10-19 (paraphrased, the 1.4.0 wave, CLAUDE.md invariant 49): every volume a non-root service
# mounts read-write is given to its uid, recursively, on every up. Each scenario is bound by name to a case
# in scripts/gates-have-teeth.sh.
Feature: an upgraded box's files are given back to the uid that writes them

  On forge, the gateway's retained-reservation journal was still owned by uid 10001 after the upgrade, and
  the gateway (uid 20010) stopped. A top-level chown does not reach a file an earlier release wrote.

  Scenario: the gateway's traces are re-owned recursively
    Given the gateway writes its traces volume read-write as uid 20010
    When init-volumes runs on an upgraded box
    Then volumes-are-reowned.sh fails if the traces volume is re-owned without a recursive chown
    # -> gates-have-teeth.sh "volumes-are-reowned: the gateway's traces are re-owned without -R, so its old journal stays uid 10001"

  Scenario: typryx's ledger volume is re-owned
    Given typryx writes its ledger volume read-write as uid 20005
    When init-volumes runs on an upgraded box
    Then volumes-are-reowned.sh fails if the ledger volume is not re-owned at all
    # -> gates-have-teeth.sh "volumes-are-reowned: typryx's ledger volume is never re-owned"

  Scenario: a chown the one-shot is refused stops it, instead of ending "volumes ready"
    Given init-volumes and costcrew-init run as root with only the capabilities their exceptions give back
    When any one chown of theirs is refused
    Then the one-shot stops with a non-zero status, so compose holds back every service that waits on it
    # -> gates-have-teeth.sh "volumes-are-reowned: init-volumes goes on past a failed chown"
    # -> gates-have-teeth.sh "volumes-are-reowned: costcrew-init goes on past a failed chown"
    # -> gates-have-teeth.sh "volumes-are-reowned: a chown and its chmod on two lines still stop the body (must pass)"

  # @claude 2026-11-12: the console's user is pinned in compose.yaml, which brings its volumes under this rule.
  Scenario: the console's state and its road to the tunnel belong to the user it runs as
    Given the console runs as the pinned 10001:10001 and writes its state volume and the wg socket's volume
    When init-volumes does not re-own the state volume, or the wg container gives its socket to another group
    Then bus-has-a-writer.sh fails and names the volume the console could not write or reach
    # -> gates-have-teeth.sh "bus-has-a-writer: the console's state volume is not re-owned"
    # -> gates-have-teeth.sh "bus-has-a-writer: the wg socket's group is not the console's"
