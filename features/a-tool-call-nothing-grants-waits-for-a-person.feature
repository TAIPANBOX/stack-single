# @decided 2026-11-07 (paraphrased): a tool call of an agent nothing grants is held for a person on a
# default box, model calls pass, only an explicit grant lifts the hold, and an existing box stops the
# upgrade with a list and changes nothing.
# Each scenario is bound by name to a case in scripts/gates-have-teeth.sh.
Feature: A tool call nothing grants waits for a person

  On a box where nobody chose anything, an agent's tool call waits for a person until
  something grants that agent that tool. Its model calls go on as before. An owner gives
  an agent a tool from the box in one command, and a box that already runs agents is told
  what would stop before anything on it changes.

  Scenario: A tool call of an agent nothing grants is held for a person
    Given a box installed with nothing said about tool calls
    When an agent nothing grants calls a tool
    Then wardryx holds the call for a person
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the floor is written as a word wardryx refuses"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the block is never written"

  Scenario: A model call of the same agent passes
    Given the same agent
    When it calls a model
    Then the call passes
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a seed grants every agent"

  Scenario: An agent id with no scheme is held and cannot be granted
    Given an agent whose id has no agent:// scheme
    When it calls a tool
    Then the call is held
    And agent-allow refuses to name it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the floor narrows to agent ids with a scheme"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: agent-allow takes a target with no trust domain"

  Scenario: A rule that only restricts an agent does not end the hold
    Given the starter rules on the fire-drill identities, and a seed that grants them
    When a seed loses its grant
    Then their tool calls wait for a person, restrictions or not
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the drills lose their seed"

  Scenario: The stack's own checks keep working
    Given a box with the typed plane
    When the installer asks its own question through the broker's static key
    Then the call passes, and that id can call nothing else
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the install-check seed is gone"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the install-check seed asks for an agent token"

  Scenario: An operator's web tools are granted under egress and nowhere else
    Given a box that reads the web
    When the operator agent fetches a page and scopyx asks about the same fetch
    Then both pass
    And a static key that names the operator is refused
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the web grant denies scopyx's question"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the web grant lets a static key borrow the name"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the web grant is on every box"

  Scenario: Felyx and CostCrew get nothing
    Given two services that make model calls only
    Then neither has a grant
    # -> gates-have-teeth.sh "tool-hold-is-seeded: felyx gets a grant it does not need"

  Scenario: TOOL_HOLD=0 removes the block and the operator's lines stay
    Given a box with the hold on and lines of the operator's own
    When it runs with TOOL_HOLD=0
    Then the block and every grant it wrote are gone
    And the operator's lines are byte for byte what they were
    # -> gates-have-teeth.sh "tool-hold-is-seeded: TOOL_HOLD=0 leaves the block"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a broken marker costs the operator lines"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a comment outside the markers is not a fault"

  Scenario: A second run changes nothing
    Given a box with all three managed blocks
    When the installer runs again
    Then policy.yaml is byte for byte what it was and wardryx is not restarted
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the block moves on every run"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a changed block does not restart wardryx"

  Scenario: A box with an ungranted caller stops the upgrade and changes nothing
    Given a box whose history holds a tool call of an agent outside the seeds
    When this release is run on it
    Then the run stops with the agent, the tool, the count and when last
    And it says how to grant and how to set TOOL_HOLD=0
    And no file changes and the journal has no line of it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the replay check is gone"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question comes after the journal's first line"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a stopped run keeps the image it pulled"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question leaves the seeds out"

  Scenario: A history that could not be asked is not a clean one
    Given a box whose decisions could not be replayed
    When this release is run on it
    Then the run stops and says how much could not be asked
    # -> gates-have-teeth.sh "tool-hold-is-seeded: unexamined decisions read as nothing to hold"

  Scenario: A line left in a file does not answer for a person
    Given TOOL_HOLD=1 in .env and a list that would stop the run
    Then the run stops all the same
    # -> gates-have-teeth.sh "tool-hold-is-seeded: .env answers for a person"

  Scenario: Text a caller wrote is never printed to paste
    Given a recorded agent id that a shell would run
    Then the table shows it and no command names it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a hostile id is printed to paste"

  Scenario: A grant made while the box was on the old release is in the question
    Given a grant in wardryx's store
    When the installer asks again
    Then that agent is off the list
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the store is left out of the question"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: an empty store breaks the question"

  Scenario: An operator gives an agent a tool from the box and the hold ends with no restart
    Given an agent whose tool call is held
    When the owner runs agent-allow with a reason
    Then the next call passes, wardryx did not restart, and policy_updated is on the record
    And the admin key was on no command line
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the admin key goes on a command line"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: agent-allow goes on with no reason"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a second grant replaces the first"

  Scenario: The widest grant says so
    When the owner runs agent-allow with all
    Then the command prints a warning
    # -> gates-have-teeth.sh "tool-hold-is-seeded: all gives no warning"

  Scenario: status says whether the floor is on and how many grants there are
    When status runs
    Then one line says it, read from the file, the store and what wardryx loaded
    # -> gates-have-teeth.sh "tool-hold-is-seeded: status prints no line"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: nothing reads what wardryx loaded"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: what wardryx loaded is read off the bus again"

  Scenario: The pin is one pin
    Given the image install.sh asks with and the image compose.yaml runs
    Then they are one digest, of 2.6.0 or later
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question runs another image"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the pin goes below 2.6.0"

  Scenario: A wardryx that cannot load the block leaves the file alone
    Given a box whose wardryx refuses when_no_grant
    Then policy.yaml is left as it was and the run says what wardryx said
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a wardryx that refuses the file gets it anyway"

  Scenario: CI's identity is the workflow's business
    Given the identity CI asks with
    Then its grant is a file of its own and no box seeds it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the installer seeds CI's identity"

  Scenario: The gate refuses to report on nothing
    Given the block is gone from install.sh
    Then the gate says it measured nothing
    # -> gates-have-teeth.sh "tool-hold-is-seeded: no block measured nothing"
