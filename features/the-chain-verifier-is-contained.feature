# @claude 2026-10-04, from the estate audit's launcher spec (wave 1): every launcher runs the
# on-box chain verifier over the events bus, because a bus nobody verifies is
# how a flipped byte went unseen on the 2026-09-17 appliance run. It must read
# every stream and write exactly one file. Scenarios are bound by name to cases
# in scripts/gates-have-teeth.sh.
Feature: the chain verifier reads the whole bus and writes only its own stream

  Its output has to be on the bus for the notifier to see, so the bus is mounted
  read-write, and compose cannot mount one file of a volume. The account it runs
  as is therefore the whole of its containment: outside the bus group, owning one
  pre-created file, with its memory on a volume of its own.

  Scenario: the verifier is put in the bus group
    Given the verifier runs outside group 10001 and has no group_add
    When it gets a group_add, or the bus gid
    Then chain-verifier-is-contained.sh fails, because it could write every plane's stream
    # -> gates-have-teeth.sh "chain-verifier: the verifier gets a group_add"
    # -> gates-have-teeth.sh "chain-verifier: the verifier joins the bus group"

  Scenario: the verifier takes the uid of a plane
    Given the verifier owns no file but its own
    When it runs as a uid the bus's writers use
    Then chain-verifier-is-contained.sh fails
    # -> gates-have-teeth.sh "chain-verifier: the verifier takes a plane's uid"

  Scenario: its memory moves onto the bus
    Given its state is on a volume of its own
    When the state file is put inside the bus directory
    Then chain-verifier-is-contained.sh fails, because the walk would read its memory as a stream
    # -> gates-have-teeth.sh "chain-verifier: its state moves onto the bus"

  Scenario: its stream is named for something else
    Given its stream is agent-conform.ndjson, the source its events claim
    When the output file is named otherwise
    Then chain-verifier-is-contained.sh fails
    # -> gates-have-teeth.sh "chain-verifier: its stream is named for something else"

  Scenario: init-volumes stops preparing its file
    Given init-volumes creates its stream and gives it to the verifier's uid alone
    When the file is not created, is given to another uid, or becomes group-writable
    Then chain-verifier-is-contained.sh fails, and so does bus-has-a-writer.sh for the unowned case
    # -> gates-have-teeth.sh "chain-verifier: init-volumes stops pre-creating its stream"
    # -> gates-have-teeth.sh "chain-verifier: its stream becomes group-writable"
    # -> gates-have-teeth.sh "chain-verifier: its stream is given to another uid"
    # -> gates-have-teeth.sh "bus-has-a-writer: the verifier's stream is given to no one it runs as"

  Scenario: its memory has no owner
    Given a fresh named volume is root:root 0755
    When init-volumes stops giving the state volume to the verifier
    Then chain-verifier-is-contained.sh fails
    # -> gates-have-teeth.sh "chain-verifier: its state volume has no owner"

  Scenario: a second writer is told to use its stream
    Given one appender per file, because the bus has no lock
    When another service names agent-conform.ndjson
    Then chain-verifier-is-contained.sh fails
    # -> gates-have-teeth.sh "chain-verifier: another plane is told to write its stream"

  Scenario: it loses its hardening, its pin or its loop
    Given it is read-only, drops every capability, runs one pinned tag and loops by itself
    When any of those is removed
    Then chain-verifier-is-contained.sh fails
    # -> gates-have-teeth.sh "chain-verifier: its root filesystem becomes writable"
    # -> gates-have-teeth.sh "chain-verifier: its image is unpinned"
    # -> gates-have-teeth.sh "chain-verifier: its loop is removed"

  Scenario: no verifier left to judge
    Given the verifier is found by its image
    When no service runs it
    Then chain-verifier-is-contained.sh says it measured nothing, never OK
    # -> gates-have-teeth.sh "chain-verifier: no verifier service left to judge"

  Scenario: a different interval and a renamed state file are not this gate's business
    Given the gate judges the account, the files and the volumes
    When the interval changes within the allowed range, or the state file is renamed
    Then chain-verifier-is-contained.sh still passes
    # -> gates-have-teeth.sh "chain-verifier: the interval changes"
    # -> gates-have-teeth.sh "chain-verifier: the state file is renamed"
