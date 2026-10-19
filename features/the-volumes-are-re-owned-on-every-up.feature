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
