# @decided 2026-10-18 (paraphrased, wave 2 of the 2026-10-17 agent-security review, the
# per-producer layout of design decision D8 a): every plane that writes the shared record
# runs under its own uid, each stream is owned by its one producer and written by nobody
# else, and the bus directory lets nobody but the setup script create a file in it.
# Each scenario is bound by name to a case in scripts/gates-have-teeth.sh.
Feature: a plane writes only its own stream

  Every plane used to run as one of two uids and every stream was writable by the
  bus group, so any plane could rewrite any other plane's record. Now the stream
  each plane writes is its own, and the record says who wrote what.

  Scenario: two producers would share one uid
    Given the gateway and the control plane each write their own stream
    When the control plane is given the gateway's uid
    Then the gate fails and names the stream whose writer shares a uid with another
    # -> gates-have-teeth.sh "no-plane-writes: two producers run as one uid"

  Scenario: a stream is readable and writable by the wrong mode
    Given every stream is created by the setup script as mode 0640
    When the setup script creates the streams as mode 0644
    Then the gate fails and names the stream whose mode is not 0640
    # -> gates-have-teeth.sh "no-plane-writes: a stream is world-readable (0644)"

  Scenario: the bus directory becomes writable by its group
    Given the bus directory is owned by root with no write bit for its group
    When the setup script makes the bus directory group-writable
    Then the gate fails, because a plane in the bus group could create a file in it
    # -> gates-have-teeth.sh "no-plane-writes: the bus directory is group-writable"

  Scenario: a reworded comment in the setup script is not a fault
    Given the gate judges what the setup script does, not what its comments say
    When a comment in the setup script is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "no-plane-writes: a reworded comment in init-volumes is not a fault"

  # @claude 2026-11-12: found when a person's first passkey grant of a held call on a live box was
  # refused, and went through only after two fixes by hand; these hold that a fresh install needs neither.
  Scenario: the console is given the bus and no stream of its own
    Given the console journals every privileged command, a person's grant among them, in console.ndjson on the bus, and refuses one it cannot journal
    When the setup script makes no console.ndjson, or gives it to another uid
    Then the gate fails and names the console, which could journal nothing and would refuse every approval
    # -> gates-have-teeth.sh "no-plane-writes: the console's stream is not created"
    # -> gates-have-teeth.sh "no-plane-writes: the console's stream is given to another uid"

  Scenario: a service that runs as the console's uid is given the bus read-write
    Given the record seal runs as the console's uid and mounts the bus read only
    When its bus mount is made read-write
    Then the gate fails and names the record seal, a service with the bus read-write and no stream of its own
    # -> gates-have-teeth.sh "no-plane-writes: a reader at the console's uid is given the bus read-write"

  Scenario: the console looks for its file outside the bus
    Given the console appends to console.ndjson in the events directory the installer's environment file names
    When that directory is not the bus the console mounts
    Then the gate fails, because the stream the setup script made is not the file the console writes
    # -> gates-have-teeth.sh "no-plane-writes: the console looks for its file outside the bus"
