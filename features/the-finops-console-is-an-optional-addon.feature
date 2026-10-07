# @decided 2026-09-25 (paraphrased): an optional add-on joins the core by
# configuration alone and leaves the core unchanged, so a box that never enables
# it runs what it ran without it. @claude 2026-10-07: the FinOps console
# (CostCrew) is such an add-on here. It is wired to the shared events bus and
# nothing else, it is started by hand, and as shipped it cannot spend. Scenarios
# are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the FinOps console is an optional add-on that leaves the core unchanged

  A box that never turns the console on must be exactly the box it was without
  it: the same services, the same volumes, the same install. The console reads
  and writes one file on the shared bus and calls nobody, and the only way to
  start it is a command a person types.

  Scenario: the console is started by something other than a person
    Given the console and its one-shot sit behind a profile of their own, finops
    When either leaves that profile, or a second profile starts it too
    Then finops-is-opt-in.sh fails, because a plain docker compose up would start it
    # -> gates-have-teeth.sh "finops: the console leaves its profile"
    # -> gates-have-teeth.sh "finops: the one-shot leaves its profile"
    # -> gates-have-teeth.sh "finops: a second profile starts the console too"
    # -> gates-have-teeth.sh "manifest-is-true: an add-on service stops sitting behind a profile"

  Scenario: the installer starts the console
    Given install.sh does not know the console exists
    When it passes the finops profile, sets it in the environment, or names the console
    Then manifest-is-true.sh and finops-is-opt-in.sh fail, because an install would start it on every box
    # -> gates-have-teeth.sh "finops: install.sh passes the profile"
    # -> gates-have-teeth.sh "finops: install.sh passes the profile (the add-on gate)"
    # -> gates-have-teeth.sh "finops: install.sh switches the profile on by environment"
    # -> gates-have-teeth.sh "finops: install.sh names the console"

  Scenario: the core learns about the console
    Given no service outside the add-on names it
    When init-volumes mounts its volume, or a core service waits for it
    Then finops-is-opt-in.sh fails, because a box that never asked for it would change
    # -> gates-have-teeth.sh "finops: init-volumes learns the add-on"
    # -> gates-have-teeth.sh "finops: a core service waits for the console"

  Scenario: the console is able to spend
    Given no gateway is named for the console, so it cannot spend as shipped
    When it is given a gateway by flag or by environment
    Then finops-is-opt-in.sh fails, because spending is the operator's separate decision
    # -> gates-have-teeth.sh "finops: the console is given a gateway"
    # -> gates-have-teeth.sh "finops: the console is given a gateway by environment"

  Scenario: the stream is not the one the readers expect
    Given its stream is costcrew.ndjson under the record plane's trust domain, and passports come with an owner
    When the stream is renamed, the owner is dropped, the host is not the trust domain, or passports leave the data volume
    Then finops-is-opt-in.sh fails, and bus-names-match-their-source.sh fails for a name or a file no reader accepts
    # -> gates-have-teeth.sh "finops: its stream is named for something else"
    # -> gates-have-teeth.sh "finops: passports come without an owner"
    # -> gates-have-teeth.sh "finops: the host is not the record plane's trust domain"
    # -> gates-have-teeth.sh "finops: its passports go outside its data volume"
    # -> gates-have-teeth.sh "bus-names: the console writes a stream no reader knows"
    # -> gates-have-teeth.sh "bus-names: the console is told to write another plane's file"

  Scenario: the console can write more of the bus than its own stream
    Given it runs as a uid of its own, outside the bus group, with no group_add and no root
    When it joins the bus group, takes a plane's uid, runs as root or gets a group_add
    Then finops-is-opt-in.sh fails, because the account is the whole of its containment
    # -> gates-have-teeth.sh "finops: the console joins the bus group"
    # -> gates-have-teeth.sh "finops: the console takes a plane's uid"
    # -> gates-have-teeth.sh "finops: the console runs as root"
    # -> gates-have-teeth.sh "finops: the console gets a group_add"

  Scenario: the console loses its hardening, its pin or its loopback address
    Given it is read-only, drops every capability, runs one pinned tag and is published on a literal 127.0.0.1
    When its filesystem becomes writable, the tag floats, or the port is published on every address or on the gateway's bind
    Then finops-is-opt-in.sh fails
    # -> gates-have-teeth.sh "finops: its root filesystem becomes writable"
    # -> gates-have-teeth.sh "finops: its image is unpinned"
    # -> gates-have-teeth.sh "finops: it is published on every address"
    # -> gates-have-teeth.sh "finops: it is published on the gateway's bind variable"

  Scenario: the one-shot stops preparing what the console writes
    Given the one-shot creates the stream for the console's uid, readable by the chain verifier, and owns the data volume
    When the stream is not created, goes to another uid, becomes group-writable or unreadable by other, or the volume has no owner
    Then finops-is-opt-in.sh fails, and bus-has-a-writer.sh fails for a volume or a stream nobody it runs as owns
    # -> gates-have-teeth.sh "finops: its stream is no longer created"
    # -> gates-have-teeth.sh "finops: its stream is given to another uid"
    # -> gates-have-teeth.sh "finops: its stream becomes group-writable"
    # -> gates-have-teeth.sh "finops: its stream cannot be read by the chain verifier"
    # -> gates-have-teeth.sh "finops: its data volume has no owner"
    # -> gates-have-teeth.sh "finops: the one-shot stops waiting for init-volumes"
    # -> gates-have-teeth.sh "finops: the console stops waiting for its one-shot"
    # -> gates-have-teeth.sh "bus-has-a-writer: the add-on's data volume is prepared by nobody"
    # -> gates-have-teeth.sh "bus-has-a-writer: the add-on's stream is given to no one it runs as"

  Scenario: the manifest stops saying what the add-on is
    Given components.json lists the console and its one-shot apart from what an install starts, each with a reason
    When a service has no reason, or the list is emptied
    Then manifest-is-true.sh fails, and says it measured nothing when the list is empty
    # -> gates-have-teeth.sh "manifest-is-true: an add-on service with no reason beside it"
    # -> gates-have-teeth.sh "manifest-is-true: the add-on list is emptied"

  Scenario: no console left to judge, or a file compose refuses
    Given the gate finds the console by its image and reads the rendering through compose
    When no service runs that image, or compose cannot render the file
    Then finops-is-opt-in.sh says it measured nothing, or that compose refused, never OK
    # -> gates-have-teeth.sh "finops: no console left to judge"
    # -> gates-have-teeth.sh "finops: compose refuses what the text read as fine"

  Scenario: a different owner default, a newer tag, another port and a comment are not this gate's business
    Given the gate judges the profile, the account, the files and the address
    When the owner's fallback changes, the tag moves within the pin form, the loopback port moves, or a comment in the core mentions the console
    Then finops-is-opt-in.sh still passes
    # -> gates-have-teeth.sh "finops: the owner default changes"
    # -> gates-have-teeth.sh "finops: the pinned tag moves"
    # -> gates-have-teeth.sh "finops: the loopback port moves"
    # -> gates-have-teeth.sh "finops: a comment in the core mentions the console"
