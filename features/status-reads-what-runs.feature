# Written from what an operator needs after an upgrade, a restore or a long weekend: to
# know whether the containers on this box are the ones the pins name, by reading and
# nothing else. This is a drift check and it is named that everywhere. It finds a box that
# has moved away from its pins by accident; the word it reports is Docker's on this box.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the drift check in status compares what runs with what was pinned

  `./install.sh status` ends with a drift check, and so does an install. For each
  container it compares what Docker runs with the pin in compose.yaml, one line each.
  The run ends 0 when everything is on its pin, 1 on drift or a failed check, and 2 when
  it could not measure.

  Scenario: status names the digest each service runs and the pin it was meant to run
    Given a box whose containers are on their pins
    When the operator runs status
    Then each service has a line with the digest it runs, its pin and where the pin came from
    # -> gates-have-teeth.sh "status-reads-what-runs: the line no longer names the pin"
    # -> gates-have-teeth.sh "status-reads-what-runs: the install does not run the drift check"

  Scenario: a container older than its pin fails status
    Given a container created from an older image, whose name still reads like the pin
    When the operator runs status
    Then its line says FAIL with both digests, and the run ends 1
    # -> gates-have-teeth.sh "status-reads-what-runs: the name of the container is read instead of its image"
    # -> gates-have-teeth.sh "status-reads-what-runs: a difference does not fail"
    # -> gates-have-teeth.sh "status-reads-what-runs: a digest in any repository is taken for the pin"
    # -> gates-have-teeth.sh "status-reads-what-runs: an image whose record is gone reads as nothing wrong"

  Scenario: the two image stores give the same verdict for the same bytes
    Given the same container on the classic image store and on the containerd store
    When the operator runs status on each
    Then both read ok, whichever digest Docker keeps in .Image and wherever the pin sits in RepoDigests
    # -> gates-have-teeth.sh "status-reads-what-runs: only .Image is compared"
    # -> gates-have-teeth.sh "status-reads-what-runs: only RepoDigests is compared"
    # -> gates-have-teeth.sh "status-reads-what-runs: only the first RepoDigest is compared"

  Scenario: an image set in .env is shown as an override
    Given a service whose image comes from a line in .env, because that replaces the pin
    When the operator runs status
    Then its line says it is a .env override and names what compose.yaml pins, and a tag with no digest fails
    # -> gates-have-teeth.sh "status-reads-what-runs: an override reads as the pin"
    # -> gates-have-teeth.sh "status-reads-what-runs: an override with no digest passes"

  Scenario: an image built on the box is named, not compared
    Given a service built here, with no registry digest to compare with
    When the operator runs status
    Then its line says it was built on this box and that there is nothing to compare
    And a service pinned by digest whose image has no registry digest fails, because it cannot be the pin
    # -> gates-have-teeth.sh "status-reads-what-runs: an image built here fails"
    # -> gates-have-teeth.sh "status-reads-what-runs: a local image under a digest pin reads as built here"

  Scenario: a one-shot that ended 0 is expected, one that ended otherwise fails
    Given the one-shots that prepare the volumes
    When the operator runs status
    Then one that ended 0 is compared like any container, and one that ended otherwise fails
    # -> gates-have-teeth.sh "status-reads-what-runs: a one-shot's exit code is ignored"

  Scenario: a service that does not stay up fails, whatever image it has
    Given a service compose keeps running that has stopped, or keeps restarting
    When the operator runs status
    Then its line gives its state and its restarts, and the run ends 1
    # -> gates-have-teeth.sh "status-reads-what-runs: a restarting container passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: a stopped core service passes"

  Scenario: a service whose profile is off is skipped and said so
    Given a service in a profile this box does not run, and a stopped service of a profile the operator starts
    When the operator runs status
    Then each is skipped and named, and neither counts as a match
    # -> gates-have-teeth.sh "status-reads-what-runs: a profile that is off is not said"
    # -> gates-have-teeth.sh "status-reads-what-runs: a skipped service counts as a match"
    # -> gates-have-teeth.sh "status-reads-what-runs: an operator's stopped profile fails"
    # -> gates-have-teeth.sh "status-reads-what-runs: every profile reads as the operator's"

  Scenario: a container on the stack's networks that compose does not know fails status
    Given a container with no project label attached to one of the stack's networks, or a label and no service
    When the operator runs status
    Then its line says unknown container, and the run ends 1
    And a throwaway that has left a moment later is not counted
    # -> gates-have-teeth.sh "status-reads-what-runs: the networks are not read"
    # -> gates-have-teeth.sh "status-reads-what-runs: a labelled container compose does not declare passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: a throwaway is reported after it has left"

  Scenario: status that cannot read Docker ends 2, not 0
    Given a Docker that does not answer, no pins to read, or no container to compare
    When the operator runs status
    Then it says it could not measure, and the run ends 2, and an install counts that as a failed check
    # -> gates-have-teeth.sh "status-reads-what-runs: a compose that will not render reads as nothing wrong"
    # -> gates-have-teeth.sh "status-reads-what-runs: zero containers reads as nothing wrong"
    # -> gates-have-teeth.sh "status-reads-what-runs: could not measure ends 0"
    # -> gates-have-teeth.sh "status-reads-what-runs: an install ignores could not measure"

  Scenario: every run says what the check cannot tell
    Given any box, in any state
    When the operator runs status
    Then one line says that this compares two things on this box, and that root on this box can change either side
    And no line and no paragraph about it claims more than a drift check can say
    # -> gates-have-teeth.sh "status-reads-what-runs: the limit line is gone"
    # -> gates-have-teeth.sh "status-reads-what-runs: a line claims more than a drift check says"
    # -> gates-have-teeth.sh "status-reads-what-runs: the README claims more than a drift check says"
    # -> gates-have-teeth.sh "status-reads-what-runs: the README does not name the drift check"

  Scenario: the drift check only reads, and reaches for no network
    Given any box
    When the operator runs status
    Then the only calls are ps, inspect, image inspect, network ls, network inspect and compose config
    # -> gates-have-teeth.sh "status-reads-what-runs: the drift check pulls an image"
    # -> gates-have-teeth.sh "status-reads-what-runs: the drift check runs cosign"

  Scenario: rewording the code around the drift check does not change a verdict
    Given the block with a comment reworded, or a column widened
    When the gate runs
    Then it still passes
    # -> gates-have-teeth.sh "status-reads-what-runs: a comment in the block is reworded"
    # -> gates-have-teeth.sh "status-reads-what-runs: a column is widened"

  Scenario: the gate does not report OK on nothing
    Given no block to lift, no function in it, no profile table or no compose services
    When the gate runs
    Then it says it measured nothing and fails
    # -> gates-have-teeth.sh "status-reads-what-runs: the block is gone"
    # -> gates-have-teeth.sh "status-reads-what-runs: the function is gone"
    # -> gates-have-teeth.sh "status-reads-what-runs: the profile table is gone"
    # -> gates-have-teeth.sh "status-reads-what-runs: compose.yaml has no services"
