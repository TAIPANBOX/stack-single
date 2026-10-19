# @decided 2026-10-19 (paraphrased, the 1.4.0 wave, CLAUDE.md invariant 52): the FinOps console can enter the
# bus directory and reach the one file it writes, and joins no group. Each scenario is bound by name to a case
# in scripts/gates-have-teeth.sh.
Feature: the FinOps console can reach its own stream on the bus

  On a fresh v1.3.1 box the costcrew container (profile finops) started and failed with "permission denied"
  on open. The file was right; the directory above it, root:10001 0750, gave a uid outside the bus group
  no way in.

  Scenario: the bus directory lets a uid outside the bus group enter it
    Given the bus directory is root:10001 and costcrew (10003) is not in the bus group
    When init-volumes sets the bus directory's mode
    Then costcrew-can-reach-its-stream.sh fails if the other-execute bit is missing
    # -> gates-have-teeth.sh "costcrew-can-reach-its-stream: the bus directory goes back to 0750, so costcrew cannot enter it"

  Scenario: costcrew joins no group, so it reads no other plane's stream
    Given costcrew runs as 10003:10003 outside the bus group
    When its service is resolved
    Then costcrew-can-reach-its-stream.sh fails if it has a group_add
    # -> gates-have-teeth.sh "costcrew-can-reach-its-stream: costcrew joins the bus group"
