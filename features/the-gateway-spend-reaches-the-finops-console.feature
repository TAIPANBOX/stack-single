# @decided 2026-11-23 (paraphrased): CostCrew, the FinOps console, gets real data
# from TokenFuse first. @claude 2026-11-23: on this box that means the FOCUS export
# runs on every install over both gateway doors, and the console reads it, read
# only, instead of showing only the estate it generates. CLAUDE.md invariant 80.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the gateway's spend reaches the FinOps console

  An agent's model calls are paid for at the gateway. The FinOps console is where a
  person reads what they cost. Until this, the two never met on this box: the export
  ran only if somebody started it by hand, it read one door of two, and the console
  was given no folder to read.

  Scenario: the export runs only when a person starts it
    Given focus-export writes the gateway's spend as FOCUS
    When it sits behind the operator's routines profile again
    Then the gate fails, because a box that sets nothing exports nothing
    # -> gates-have-teeth.sh "costcrew-reads-spend: focus-export goes back behind the routines profile"
    # -> gates-have-teeth.sh "manifest-is-true: a scheduled routine sits behind an operator profile"

  Scenario: one door's spend is never exported
    Given the box can run a second gateway, the OpenAI door, with traces of its own
    When focus-export reads the main gateway's traces only
    Then the gate fails, because the door's calls never reach the console
    # -> gates-have-teeth.sh "costcrew-reads-spend: focus-export reads one door"

  Scenario: the console is given no folder to read
    Given the console reads the gateway's export only from the folders it is started with
    When it loses -focus-dir, or -focus-dir-openai, or names one folder as both doors
    Then the gate fails, because the console would show the generated estate beside a gateway that served real agents
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console loses -focus-dir"
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console loses the OpenAI door's folder"
    # -> gates-have-teeth.sh "costcrew-reads-spend: one folder named as both doors"
    # -> gates-have-teeth.sh "costcrew-reads-spend: the generated estate is never replaced"

  Scenario: the console can change the money it reads
    Given the console only reads the export
    When it mounts the focus volume read-write, or does not mount it at all
    Then the gate fails
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console mounts the export read-write"
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console does not mount the export"

  Scenario: the console cannot read the folders it is given
    Given the console runs outside the bus group and joins no group
    When init-volumes stops making a door's folder, or closes it to other users
    Then the gate fails, because the console refuses to start on a folder it cannot open
    # -> gates-have-teeth.sh "costcrew-reads-spend: init-volumes stops making a door's folder"
    # -> gates-have-teeth.sh "costcrew-reads-spend: a door's folder is closed to other users"

  Scenario: the export grows without bound or is read half written
    Given focus-export exports the whole trace every window
    When it writes a new timestamped file each window, or writes straight into the name the console reads
    Then the gate fails
    # -> gates-have-teeth.sh "costcrew-reads-spend: a new file every window"
    # -> gates-have-teeth.sh "costcrew-reads-spend: the export is written straight into the name the console reads"

  Scenario: an empty window throws the last good export away
    Given a window can find no new call
    When focus-export deletes the door's file on such a window
    Then the gate fails, because the console would lose the spend it had
    # -> gates-have-teeth.sh "costcrew-reads-spend: an empty window deletes the last export"

  Scenario: a door that has never exported blocks the other door's spend
    Given the console refuses a configured folder with nothing in it, and the whole import with it
    When a door that served nothing is left with no file, or header-only files are written with no real export beside them
    Then the gate fails, because the console would read neither door, or wipe its demo data with no call to show
    # -> gates-have-teeth.sh "costcrew-reads-spend: a door that never exported gets no file"
    # -> gates-have-teeth.sh "costcrew-reads-spend: header-only files with no real export beside them"

  Scenario: the install stops asking whether the export runs
    Given install.sh checks every box at the end of a run and in status
    When the focus-export check is gone
    Then the gate fails
    # -> gates-have-teeth.sh "costcrew-reads-spend: install.sh stops checking the export"

  Scenario: nothing is left to judge
    Given the gate reads focus-export, the console and init-volumes
    When focus-export is gone from compose.yaml
    Then the gate says it measured nothing rather than OK
    # -> gates-have-teeth.sh "costcrew-reads-spend: focus-export is gone (measured nothing)"

  Scenario: a harmless change is not a fault
    Given the export interval is the operator's to choose
    When its default moves from 15 to 30 minutes
    Then the gate still passes
    # -> gates-have-teeth.sh "costcrew-reads-spend: a longer export interval (must pass)"
