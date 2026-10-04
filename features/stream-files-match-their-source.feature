# @claude 2026-10-04, from the estate audit's launcher spec (wave 1): heraldyx and idryx now
# refuse an event whose source the file it came from may not carry. A launcher
# that writes a file under a name that does not match its writer's source would
# lose that plane's alerts with every check green. Scenarios are bound by name
# to cases in scripts/gates-have-teeth.sh.
Feature: every stream file this launcher writes is one the readers accept

  The default is that `<source>.ndjson` carries `<source>`, plus
  `tokenfuse-cloud.ndjson` and `tokenfuse-mcp.ndjson` carrying `tokenfuse`. The
  preferred repair for a mismatch is to rename the file; declaring a stream
  widens what the box accepts from anything that can create a file there.

  Scenario: a writer's file is renamed to a name nobody reads
    Given every writer's file is named for the source it claims
    When the MCP broker's file becomes mcp-events.ndjson
    Then bus-names-match-their-source.sh fails and names the file
    # -> gates-have-teeth.sh "bus-names: a writer's file is renamed to nothing anyone reads"

  Scenario: a plane writes a file named for another plane
    Given wardryx writes wardryx.ndjson claiming wardryx
    When it is told to write typryx.ndjson
    Then bus-names-match-their-source.sh fails, because both readers would refuse every line
    # -> gates-have-teeth.sh "bus-names: wardryx writes a file named for another plane"

  Scenario: idryx is told to load a file for a source it does not carry
    Given idryx loads tokenfuse from tokenfuse.ndjson
    When it is told to load that file as wardryx
    Then bus-names-match-their-source.sh fails
    # -> gates-have-teeth.sh "bus-names: idryx loads a file for a source it does not carry"

  Scenario: init-volumes prepares a stream nobody accepts
    Given every pre-created file has a name the readers accept
    When init-volumes pre-creates events.ndjson
    Then bus-names-match-their-source.sh fails
    # -> gates-have-teeth.sh "bus-names: init-volumes pre-creates a stream nobody accepts"

  Scenario: a declaration widens the rule instead of a rename
    Given no service sets HERALDYX_STREAMS or IDRYX_STREAMS
    When one is set
    Then bus-names-match-their-source.sh fails
    # -> gates-have-teeth.sh "bus-names: a declaration widens the rule"

  Scenario: nothing loads a stream any more
    Given idryx loads the gateway's file
    When no service loads anything
    Then bus-names-match-their-source.sh says it measured nothing, never OK
    # -> gates-have-teeth.sh "bus-names: nothing loads a stream any more"

  Scenario: a comment is not a stream
    Given the gate reads the files and the loads, not the prose
    When a comment in init-volumes changes
    Then bus-names-match-their-source.sh still passes
    # -> gates-have-teeth.sh "bus-names: a comment in init-volumes changes"
