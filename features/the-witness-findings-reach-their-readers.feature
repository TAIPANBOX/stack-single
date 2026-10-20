# @decided 2026-10-20 (paraphrased): the Keyryx witness's findings reach the console and
# the notifier by giving those readers read-only access to the witness's own findings
# file; the witness is never given write access to the bus it witnesses. Each scenario is
# bound by name to a case in scripts/gates-have-teeth.sh.
Feature: the Keyryx witness's findings reach the console and the notifier, read only

  The witness notices when a stream on the bus was rewritten after it was seen. If it
  could write the bus, a compromised witness could add lines to the record it vouches
  for. So its findings are a file of their own, keyryx.ndjson, on a volume of their own,
  and heraldyx and the console read that file through a read-only mount.

  Scenario: the witness writes its findings onto the bus
    Given the witness writes keyryx.ndjson on the keyryxalerts volume
    When its findings file is moved into the bus directory it reads
    Then the gate fails, because the witness would write the bus it witnesses
    # -> gates-have-teeth.sh "keyryx-alerts: the witness writes its findings onto the bus"

  Scenario: the witness mounts the bus read-write
    Given the witness mounts the bus read only
    When its mount of the bus loses the read-only flag
    Then the gate fails and names the bus volume
    # -> gates-have-teeth.sh "keyryx-alerts: the witness mounts the bus read-write"

  Scenario: the findings go back to the witness's private state volume
    Given the witness keeps its log and its keys on a state volume no reader mounts
    When its findings file is put back on that state volume
    Then the gate fails, because a reader would then need the witness's state
    # -> gates-have-teeth.sh "keyryx-alerts: the findings go back to the witness's state volume"

  Scenario: a reader mounts the findings read-write
    Given heraldyx mounts the findings volume read only
    When heraldyx mounts it read-write
    Then the gate fails, because only the witness writes its findings
    # -> gates-have-teeth.sh "keyryx-alerts: heraldyx mounts the findings read-write"

  Scenario: heraldyx is not told to read the findings
    Given HERALDYX_EVENTS names the bus and the findings file
    When it names the bus alone
    Then the gate fails, because no finding would be mailed
    # -> gates-have-teeth.sh "keyryx-alerts: heraldyx is not told to read the findings"

  Scenario: the console is not told to read the findings
    Given GENARYX_EVENTS_EXTRA names the findings file
    When the console loses that setting
    Then the gate fails, because no finding would become an incident
    # -> gates-have-teeth.sh "keyryx-alerts: the console is not told to read the findings"

  Scenario: the findings file is writable by the readers' group
    Given init-volumes creates keyryx.ndjson owned by the witness, mode 0640
    When it is made mode 0660
    Then the gate fails, because a reader in the bus group could then write a finding
    # -> gates-have-teeth.sh "keyryx-alerts: the findings file is writable by the readers' group"

  Scenario: the findings file loses the stem heraldyx reads as keyryx
    Given heraldyx 0.8.0 reads source keyryx from a file named keyryx.ndjson
    When the witness writes alerts.ndjson instead
    Then bus-names-match-their-source.sh fails, because heraldyx would refuse every finding
    # -> gates-have-teeth.sh "bus-names: the witness's findings file loses its keyryx stem"

  Scenario: heraldyx is pinned before the release that reads keyryx
    Given heraldyx 0.8.0 is the first release that reads and renders the keyryx source
    When compose.yaml pins heraldyx 0.7.0
    Then bus-names-match-their-source.sh fails and names the pin
    # -> gates-have-teeth.sh "bus-names: the heraldyx pin goes back before the keyryx source"

  Scenario: a reworded comment is not a fault
    Given the gate judges the resolved configuration
    When a comment beside the findings volume is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "keyryx-alerts: a reworded comment beside the findings volume is not a fault"

  Scenario: the witness service is gone
    Given the gate judges the witness by its service name
    When the witness service is renamed away
    Then the gate reports that it measured nothing, and does not pass
    # -> gates-have-teeth.sh "keyryx-alerts: no witness service left to judge"
