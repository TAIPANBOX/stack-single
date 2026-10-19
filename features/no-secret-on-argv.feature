# @decided 2026-10-17 (paraphrased, the agent-security review's finding F-015): the
# installer and its health checks must not put a credential on a process's argument
# list, where any local user can read it. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name, and scripts/features-are-bound.sh holds the
# binding both ways. Invariant 46 in CLAUDE.md, gated by scripts/no-secret-on-argv.sh.

Feature: no credential rides on a process's argument list

  An argument list is readable by every local user, and a container's command
  line stays in docker inspect for as long as the container exists. The checks
  that prove the stack answers its own keys used to send those keys as headers on
  a docker run command line. The keys now travel on the request, through stdin,
  and a token travels in the environment of the one command that reads it.

  Scenario: a probe sends a key without putting it on any command line
    Given the installer checks that the policy plane accepts its admin key
    When the check sends the key to the throwaway container
    Then the key is in the request on stdin, and no argument of docker or of the container carries it
    # -> gates-have-teeth.sh "no-secret-on-argv: the request helper passes the key as an argument"
    # -> gates-have-teeth.sh "no-secret-on-argv: a header goes back on a command line"

  Scenario: a helper that takes a key still sends its request with a body
    Given a metered call is made with a client key and a JSON body
    When the request helper sends it
    Then the body carries its Content-Length, and the key is on stdin only
    # -> gates-have-teeth.sh "no-secret-on-argv: the request helper passes the key as an argument"

  Scenario: a comment that names a header flag is not a fault
    Given the header flag is described in a comment
    When the installer's wording changes but no command line does
    Then no-secret-on-argv.sh still reports OK
    # -> gates-have-teeth.sh "no-secret-on-argv: a comment naming a header flag is not a fault"

  Scenario: the console clone never puts its token in a URL
    Given the console is cloned with a token when no public clone is possible
    When the installer clones it
    Then the token reaches git from the environment through a credential helper, and the clone URL carries no credential
    # -> gates-have-teeth.sh "no-secret-on-argv: the console clone puts the token back in its URL"
    # -> gates-have-teeth.sh "no-secret-on-argv: the credential helper stops handing git the token"

  Scenario: the clone does not lose its credential helper
    Given the clone reads its token through a credential helper
    When the helper is removed and the clone passes the token some other way
    Then no-secret-on-argv.sh fails, because it no longer finds the helper it judges
    # -> gates-have-teeth.sh "no-secret-on-argv: the console clone no longer uses a credential helper"

  Scenario: a secret is never expanded into a docker command or a compose command
    Given a secret value is available to the installer
    When a docker run line or a compose command, entrypoint, healthcheck or flag would carry it
    Then no-secret-on-argv.sh fails and names the line
    # -> gates-have-teeth.sh "no-secret-on-argv: a secret expanded into a docker command is refused"
    # -> gates-have-teeth.sh "no-secret-on-argv: a compose command carries a secret"

  Scenario: the gate refuses to call the tree clean when it measured nothing
    Given the request helper is the thing this gate reads
    When its markers are gone
    Then no-secret-on-argv.sh fails rather than reporting OK over nothing
    # -> gates-have-teeth.sh "no-secret-on-argv: the request helper is gone"
