# @claude 2026-11-04, from the task that wired the console's policy and budget proofs into this
# launcher (it records no decision of the owner): the console replays a candidate policy against
# wardryx's policy archive and backtests a candidate budget over the gateway's traces, so it has
# to reach both and may only read them. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh.
Feature: the console reaches what its proofs run on, and can only read it

  A proof is only as good as what it runs on. Measured on a box with wardryx v2.4.1, the console
  could not open one file of the policy archive, and `wardryx replay` said "not archived" for every
  decision: its word for a version it never kept, said of versions the console could not read. So
  the console is told where the archive and the traces are, runs in the group wardryx writes its
  archive in, reads the traces through a read-only mount, and every start makes the versions an
  earlier wardryx wrote readable to that group and to nobody else.

  Scenario: the console is not told where the archive is
    Given the console runs the policy proof against the archive wardryx writes
    When the console loses WARDRYX_POLICY_ARCHIVE
    Then the gate fails, because the proof would report itself not configured
    # -> gates-have-teeth.sh "console-proofs: the console is not told where the archive is"

  Scenario: the console reads another directory than the archive wardryx writes
    Given the console and wardryx name the same archive directory on the same volume
    When the console is pointed at a copy of the directory name
    Then the gate fails and says it is not the archive wardryx writes
    # -> gates-have-teeth.sh "console-proofs: the console reads another directory than the archive wardryx writes"

  Scenario: the console is not told where the traces are
    Given the console backtests a budget over the gateway's recorded calls
    When the console loses TOKENFUSE_DATA_DIR
    Then the gate fails, because the budget proof would report itself not configured
    # -> gates-have-teeth.sh "console-proofs: the console is not told where the traces are"

  Scenario: the console reads the OpenAI door's traces instead of the gateway's
    Given the console reads the Anthropic gateway's trace directory
    When its TOKENFUSE_DATA_DIR names the OpenAI door's directory
    Then the gate fails, because a budget would be backtested over the wrong calls
    # -> gates-have-teeth.sh "console-proofs: the console reads the OpenAI door's traces, not the gateway's"

  Scenario: the console can edit the traces
    Given the console mounts the trace volume read only
    When its mount loses the read-only flag
    Then the gate fails and names the volume
    # -> gates-have-teeth.sh "console-proofs: the console mounts the traces read-write"

  Scenario: the console has no mount of the gateway's volume where the traces are
    Given the console's trace directory is a path in the gateway's volume
    When a different volume is mounted at that path
    Then the gate fails, because the console would read an empty directory
    # -> gates-have-teeth.sh "console-proofs: the console mounts a different volume where the traces are"

  Scenario: wardryx writes its archive in a group the console is not in
    Given wardryx and the console run in the same group
    When wardryx is moved to another group
    Then the gate fails, because a version would be 0640 in a group the console cannot use
    # -> gates-have-teeth.sh "console-proofs: wardryx runs in a group the console is not in"

  Scenario: the archive directory lets the console change the archive
    Given the archive directory is mode 0750 for wardryx's uid and the console's group
    When it is made group-writable
    Then the gate fails, because the console could add or remove a version
    # -> gates-have-teeth.sh "console-proofs: the archive directory is group-writable"

  Scenario: the archive directory is open to every other account
    Given the archive directory has nothing for other
    When it is made readable by everyone
    Then the gate fails
    # -> gates-have-teeth.sh "console-proofs: the archive directory is open to other"

  Scenario: the archive directory belongs to another plane
    Given the archive directory is owned by wardryx's uid
    When it is given to another plane's uid
    Then the gate fails, because wardryx could no longer write a version
    # -> gates-have-teeth.sh "console-proofs: the archive directory is owned by another plane"

  Scenario: the archive directory is in a group the console is not in
    Given the archive directory is given to the group the console runs in
    When it is given to another group
    Then the gate fails, because the console could not list the versions
    # -> gates-have-teeth.sh "console-proofs: the archive directory is in a group the console is not in"

  Scenario: the archive is given away without reaching the versions inside it
    Given the archive is given to wardryx recursively on every start
    When the chown stops being recursive
    Then the gate fails, because a version an earlier wardryx wrote keeps its old owner
    # -> gates-have-teeth.sh "console-proofs: the archive is given away without a recursive chown"

  Scenario: a version an earlier wardryx wrote stays unreadable
    Given a version written before v2.5.1 is 0600
    When the start no longer makes it readable
    Then the gate fails, because the console would read it as not archived
    # -> gates-have-teeth.sh "console-proofs: versions an earlier wardryx wrote stay 0600"

  Scenario: the versions are made readable by everyone
    Given the versions are made 0640
    When they are made 0644
    Then the gate fails, because nothing but wardryx and the console should read a policy
    # -> gates-have-teeth.sh "console-proofs: versions are made readable by everyone"

  Scenario: the versions are made writable by the group
    Given the versions are made 0640
    When they are made 0660
    Then the gate fails, because the console could change a recorded policy
    # -> gates-have-teeth.sh "console-proofs: versions are made writable by the group"

  Scenario: wardryx names no archive
    Given the gate reads wardryx's own archive setting
    When wardryx has none
    Then the gate says it measured nothing instead of reporting OK
    # -> gates-have-teeth.sh "console-proofs: wardryx names no archive, so there is nothing to read"

  Scenario: a reworded comment is not a fault
    Given the repair of the versions' modes is commented
    When the comment is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "console-proofs: a reworded comment above the repair is not a fault"

  Scenario: leaving the console's account to its image is not a fault
    Given compose names the console's account, 10001:10001, the same one its image runs as
    When the name is taken out and the image's account applies
    Then the gate still passes
    # -> gates-have-teeth.sh "console-proofs: leaving the console's account to its image is not a fault"
